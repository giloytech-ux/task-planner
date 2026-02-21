-- Fix: RLS policies on tasks/chat_history reference projects (which has RLS),
-- creating a cross-table RLS evaluation chain that causes query timeouts.
-- Solution: SECURITY DEFINER helper functions bypass RLS on inner lookups.

-- =============================================
-- 1. Helper functions (SECURITY DEFINER = bypass RLS)
-- =============================================

-- Check if current user owns a project
CREATE OR REPLACE FUNCTION is_project_owner(p_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM projects WHERE id = p_id AND user_id = auth.uid()
    );
$$;

-- Check if current user has any access (owner OR shared)
CREATE OR REPLACE FUNCTION has_project_access(p_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM projects WHERE id = p_id AND user_id = auth.uid()
    )
    OR EXISTS (
        SELECT 1 FROM project_shares
        WHERE project_id = p_id AND shared_with_id = auth.uid()
    );
$$;

-- Check if current user can edit (owner OR shared editor)
CREATE OR REPLACE FUNCTION has_project_edit_access(p_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM projects WHERE id = p_id AND user_id = auth.uid()
    )
    OR EXISTS (
        SELECT 1 FROM project_shares
        WHERE project_id = p_id
          AND shared_with_id = auth.uid()
          AND role = 'editor'
    );
$$;

-- =============================================
-- 2. Fix tasks RLS — use helper functions instead of subqueries on projects
-- =============================================

DROP POLICY IF EXISTS "Owner full access on tasks" ON tasks;
DROP POLICY IF EXISTS "Shared users can view tasks" ON tasks;
DROP POLICY IF EXISTS "Shared editors can update tasks" ON tasks;

CREATE POLICY "Owner full access on tasks"
    ON tasks FOR ALL
    USING (is_project_owner(project_id))
    WITH CHECK (is_project_owner(project_id));

CREATE POLICY "Shared users can view tasks"
    ON tasks FOR SELECT
    USING (has_project_access(project_id));

CREATE POLICY "Shared editors can update tasks"
    ON tasks FOR UPDATE
    USING (has_project_edit_access(project_id));

-- =============================================
-- 3. Fix chat_history RLS — same pattern
-- =============================================

DROP POLICY IF EXISTS "Owner full access on chat_history" ON chat_history;
DROP POLICY IF EXISTS "Shared users can view chat_history" ON chat_history;

CREATE POLICY "Owner full access on chat_history"
    ON chat_history FOR ALL
    USING (is_project_owner(project_id))
    WITH CHECK (is_project_owner(project_id));

CREATE POLICY "Shared users can view chat_history"
    ON chat_history FOR SELECT
    USING (has_project_access(project_id));
