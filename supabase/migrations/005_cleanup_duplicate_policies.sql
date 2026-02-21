-- Cleanup: drop old duplicate policies and optimize auth.uid() calls
-- Two issues fixed:
-- 1. Pre-existing policies ("Users manage own ...") overlap with our new policies
-- 2. auth.uid() should be wrapped in (select auth.uid()) for per-statement caching

-- =============================================
-- 1. Drop old duplicate policies (created before sharing migration)
-- =============================================

DROP POLICY IF EXISTS "Users manage own projects" ON projects;
DROP POLICY IF EXISTS "Users manage own tasks" ON tasks;
DROP POLICY IF EXISTS "Users manage own chat history" ON chat_history;

-- =============================================
-- 2. Update helper functions to use (select auth.uid())
-- =============================================

CREATE OR REPLACE FUNCTION is_project_owner(p_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM projects WHERE id = p_id AND user_id = (select auth.uid())
    );
$$;

CREATE OR REPLACE FUNCTION has_project_access(p_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM projects WHERE id = p_id AND user_id = (select auth.uid())
    )
    OR EXISTS (
        SELECT 1 FROM project_shares
        WHERE project_id = p_id AND shared_with_id = (select auth.uid())
    );
$$;

CREATE OR REPLACE FUNCTION has_project_edit_access(p_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM projects WHERE id = p_id AND user_id = (select auth.uid())
    )
    OR EXISTS (
        SELECT 1 FROM project_shares
        WHERE project_id = p_id
          AND shared_with_id = (select auth.uid())
          AND role = 'editor'
    );
$$;

-- =============================================
-- 3. Recreate projects policies with (select auth.uid())
-- =============================================

DROP POLICY IF EXISTS "Owner full access on projects" ON projects;
DROP POLICY IF EXISTS "Shared users can view projects" ON projects;
DROP POLICY IF EXISTS "Shared editors can update projects" ON projects;

CREATE POLICY "Owner full access on projects"
    ON projects FOR ALL
    USING ((select auth.uid()) = user_id)
    WITH CHECK ((select auth.uid()) = user_id);

CREATE POLICY "Shared users can view projects"
    ON projects FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM project_shares
            WHERE project_shares.project_id = projects.id
              AND project_shares.shared_with_id = (select auth.uid())
        )
    );

CREATE POLICY "Shared editors can update projects"
    ON projects FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM project_shares
            WHERE project_shares.project_id = projects.id
              AND project_shares.shared_with_id = (select auth.uid())
              AND project_shares.role = 'editor'
        )
    );

-- =============================================
-- 4. Recreate project_shares policies with (select auth.uid())
-- =============================================

DROP POLICY IF EXISTS "Owners and shared users can view shares" ON project_shares;
DROP POLICY IF EXISTS "Only owners can create shares" ON project_shares;
DROP POLICY IF EXISTS "Owners or shared users can remove shares" ON project_shares;

CREATE POLICY "Owners and shared users can view shares"
    ON project_shares FOR SELECT
    USING ((select auth.uid()) = owner_id OR (select auth.uid()) = shared_with_id);

CREATE POLICY "Only owners can create shares"
    ON project_shares FOR INSERT
    WITH CHECK ((select auth.uid()) = owner_id);

CREATE POLICY "Owners or shared users can remove shares"
    ON project_shares FOR DELETE
    USING ((select auth.uid()) = owner_id OR (select auth.uid()) = shared_with_id);

-- =============================================
-- 5. Recreate user_profiles policies with (select auth.uid())
-- =============================================

DROP POLICY IF EXISTS "Users can view own profile" ON user_profiles;
DROP POLICY IF EXISTS "Users can update own profile" ON user_profiles;
DROP POLICY IF EXISTS "Users can insert own profile" ON user_profiles;

CREATE POLICY "Users can view own profile"
    ON user_profiles FOR SELECT
    USING ((select auth.uid()) = id);

CREATE POLICY "Users can update own profile"
    ON user_profiles FOR UPDATE
    USING ((select auth.uid()) = id);

CREATE POLICY "Users can insert own profile"
    ON user_profiles FOR INSERT
    WITH CHECK ((select auth.uid()) = id);

-- =============================================
-- 6. Update RPC functions to use (select auth.uid())
-- =============================================

CREATE OR REPLACE FUNCTION share_project(p_project_id UUID, p_email TEXT, p_role TEXT DEFAULT 'viewer')
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_owner_id UUID;
    v_target_id UUID;
    v_project_owner UUID;
BEGIN
    IF p_role NOT IN ('viewer', 'editor') THEN
        RETURN jsonb_build_object('error', 'invalid_role');
    END IF;

    v_owner_id := (select auth.uid());

    SELECT user_id INTO v_project_owner
    FROM projects
    WHERE id = p_project_id;

    IF v_project_owner IS NULL THEN
        RETURN jsonb_build_object('error', 'project_not_found');
    END IF;

    IF v_project_owner != v_owner_id THEN
        RETURN jsonb_build_object('error', 'not_owner');
    END IF;

    SELECT id INTO v_target_id
    FROM auth.users
    WHERE email = lower(trim(p_email));

    IF v_target_id IS NULL THEN
        RETURN jsonb_build_object('error', 'user_not_found');
    END IF;

    IF v_target_id = v_owner_id THEN
        RETURN jsonb_build_object('error', 'cannot_share_self');
    END IF;

    IF EXISTS (
        SELECT 1 FROM project_shares
        WHERE project_id = p_project_id AND shared_with_id = v_target_id
    ) THEN
        RETURN jsonb_build_object('error', 'already_shared');
    END IF;

    INSERT INTO project_shares (project_id, owner_id, shared_with_id, role)
    VALUES (p_project_id, v_owner_id, v_target_id, p_role);

    RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION get_project_shares(p_project_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_owner_id UUID;
    v_project_owner UUID;
    v_result JSONB;
BEGIN
    v_owner_id := (select auth.uid());

    SELECT user_id INTO v_project_owner
    FROM projects
    WHERE id = p_project_id;

    IF v_project_owner != v_owner_id THEN
        RETURN '[]'::jsonb;
    END IF;

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', ps.id,
            'email', u.email,
            'role', ps.role,
            'created_at', ps.created_at
        ) ORDER BY ps.created_at
    ), '[]'::jsonb)
    INTO v_result
    FROM project_shares ps
    JOIN auth.users u ON u.id = ps.shared_with_id
    WHERE ps.project_id = p_project_id;

    RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION remove_project_share(p_share_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_caller UUID;
    v_share RECORD;
BEGIN
    v_caller := (select auth.uid());

    SELECT * INTO v_share
    FROM project_shares
    WHERE id = p_share_id;

    IF v_share IS NULL THEN
        RETURN jsonb_build_object('error', 'share_not_found');
    END IF;

    IF v_caller != v_share.owner_id AND v_caller != v_share.shared_with_id THEN
        RETURN jsonb_build_object('error', 'not_authorized');
    END IF;

    DELETE FROM project_shares WHERE id = p_share_id;

    RETURN jsonb_build_object('success', true);
END;
$$;
