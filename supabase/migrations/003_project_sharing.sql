-- Project Sharing: table, RLS policies, RPC functions, storage policies

-- =============================================
-- 1a. project_shares table
-- =============================================
CREATE TABLE project_shares (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    owner_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    shared_with_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'viewer' CHECK (role IN ('viewer', 'editor')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(project_id, shared_with_id)
);
CREATE INDEX idx_shares_shared_with ON project_shares(shared_with_id);
CREATE INDEX idx_shares_project ON project_shares(project_id);

-- =============================================
-- 1b. RLS on project_shares
-- =============================================
ALTER TABLE project_shares ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Owners and shared users can view shares"
    ON project_shares FOR SELECT
    USING (auth.uid() = owner_id OR auth.uid() = shared_with_id);

CREATE POLICY "Only owners can create shares"
    ON project_shares FOR INSERT
    WITH CHECK (auth.uid() = owner_id);

CREATE POLICY "Owners or shared users can remove shares"
    ON project_shares FOR DELETE
    USING (auth.uid() = owner_id OR auth.uid() = shared_with_id);

-- =============================================
-- 1c. RLS on projects (currently has NONE)
-- =============================================
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;

-- Owner has full access
CREATE POLICY "Owner full access on projects"
    ON projects FOR ALL
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- Shared users can SELECT
CREATE POLICY "Shared users can view projects"
    ON projects FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM project_shares
            WHERE project_shares.project_id = projects.id
              AND project_shares.shared_with_id = auth.uid()
        )
    );

-- Shared editors can UPDATE (metadata only — enforced at app level)
CREATE POLICY "Shared editors can update projects"
    ON projects FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM project_shares
            WHERE project_shares.project_id = projects.id
              AND project_shares.shared_with_id = auth.uid()
              AND project_shares.role = 'editor'
        )
    );

-- =============================================
-- 1d. RLS on tasks (currently has NONE)
-- =============================================
ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;

-- Owner has full access (join through projects)
CREATE POLICY "Owner full access on tasks"
    ON tasks FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = tasks.project_id
              AND projects.user_id = auth.uid()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = tasks.project_id
              AND projects.user_id = auth.uid()
        )
    );

-- Shared users can SELECT
CREATE POLICY "Shared users can view tasks"
    ON tasks FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM project_shares
            WHERE project_shares.project_id = tasks.project_id
              AND project_shares.shared_with_id = auth.uid()
        )
    );

-- Shared editors can UPDATE tasks (field restrictions enforced at app level)
CREATE POLICY "Shared editors can update tasks"
    ON tasks FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM project_shares
            WHERE project_shares.project_id = tasks.project_id
              AND project_shares.shared_with_id = auth.uid()
              AND project_shares.role = 'editor'
        )
    );

-- =============================================
-- 1e. RLS on chat_history (currently has NONE)
-- =============================================
ALTER TABLE chat_history ENABLE ROW LEVEL SECURITY;

-- Owner has full access
CREATE POLICY "Owner full access on chat_history"
    ON chat_history FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = chat_history.project_id
              AND projects.user_id = auth.uid()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = chat_history.project_id
              AND projects.user_id = auth.uid()
        )
    );

-- Shared users can SELECT chat history (read summaries)
CREATE POLICY "Shared users can view chat_history"
    ON chat_history FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM project_shares
            WHERE project_shares.project_id = chat_history.project_id
              AND project_shares.shared_with_id = auth.uid()
        )
    );

-- =============================================
-- 1f. RPC functions (SECURITY DEFINER)
-- =============================================

-- share_project: validates ownership, looks up email, creates share
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
    -- Validate role
    IF p_role NOT IN ('viewer', 'editor') THEN
        RETURN jsonb_build_object('error', 'invalid_role');
    END IF;

    v_owner_id := auth.uid();

    -- Check project ownership
    SELECT user_id INTO v_project_owner
    FROM projects
    WHERE id = p_project_id;

    IF v_project_owner IS NULL THEN
        RETURN jsonb_build_object('error', 'project_not_found');
    END IF;

    IF v_project_owner != v_owner_id THEN
        RETURN jsonb_build_object('error', 'not_owner');
    END IF;

    -- Look up target user by email
    SELECT id INTO v_target_id
    FROM auth.users
    WHERE email = lower(trim(p_email));

    IF v_target_id IS NULL THEN
        RETURN jsonb_build_object('error', 'user_not_found');
    END IF;

    -- Cannot share with self
    IF v_target_id = v_owner_id THEN
        RETURN jsonb_build_object('error', 'cannot_share_self');
    END IF;

    -- Check if already shared
    IF EXISTS (
        SELECT 1 FROM project_shares
        WHERE project_id = p_project_id AND shared_with_id = v_target_id
    ) THEN
        RETURN jsonb_build_object('error', 'already_shared');
    END IF;

    -- Create the share
    INSERT INTO project_shares (project_id, owner_id, shared_with_id, role)
    VALUES (p_project_id, v_owner_id, v_target_id, p_role);

    RETURN jsonb_build_object('success', true);
END;
$$;

-- get_project_shares: returns shares for a project (owner only)
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
    v_owner_id := auth.uid();

    -- Check project ownership
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

-- remove_project_share: owner or shared user can remove a share
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
    v_caller := auth.uid();

    SELECT * INTO v_share
    FROM project_shares
    WHERE id = p_share_id;

    IF v_share IS NULL THEN
        RETURN jsonb_build_object('error', 'share_not_found');
    END IF;

    -- Only owner or the shared user can remove
    IF v_caller != v_share.owner_id AND v_caller != v_share.shared_with_id THEN
        RETURN jsonb_build_object('error', 'not_authorized');
    END IF;

    DELETE FROM project_shares WHERE id = p_share_id;

    RETURN jsonb_build_object('success', true);
END;
$$;

-- =============================================
-- 1g. Storage policies for task-files bucket
-- =============================================
-- Shared users can read files from projects shared with them
CREATE POLICY "Shared users can read task files"
    ON storage.objects FOR SELECT
    USING (
        bucket_id = 'task-files'
        AND EXISTS (
            SELECT 1 FROM project_shares ps
            JOIN projects p ON p.id = ps.project_id
            WHERE ps.shared_with_id = auth.uid()
              AND (storage.foldername(name))[1] = p.user_id::text
              AND (storage.foldername(name))[2] = ps.project_id::text
        )
    );

-- Shared editors can upload files to projects shared with them
CREATE POLICY "Shared editors can upload task files"
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'task-files'
        AND EXISTS (
            SELECT 1 FROM project_shares ps
            JOIN projects p ON p.id = ps.project_id
            WHERE ps.shared_with_id = auth.uid()
              AND ps.role = 'editor'
              AND (storage.foldername(name))[1] = p.user_id::text
              AND (storage.foldername(name))[2] = ps.project_id::text
        )
    );

-- Shared editors can delete files from projects shared with them
CREATE POLICY "Shared editors can delete task files"
    ON storage.objects FOR DELETE
    USING (
        bucket_id = 'task-files'
        AND EXISTS (
            SELECT 1 FROM project_shares ps
            JOIN projects p ON p.id = ps.project_id
            WHERE ps.shared_with_id = auth.uid()
              AND ps.role = 'editor'
              AND (storage.foldername(name))[1] = p.user_id::text
              AND (storage.foldername(name))[2] = ps.project_id::text
        )
    );
