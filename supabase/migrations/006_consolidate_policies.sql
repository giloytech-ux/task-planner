-- Consolidate: replace FOR ALL + per-action policies with single policy per action
-- This eliminates "multiple permissive policies" warnings

-- =============================================
-- 1. projects — merge owner + shared into one policy per action
-- =============================================

DROP POLICY IF EXISTS "Owner full access on projects" ON projects;
DROP POLICY IF EXISTS "Shared users can view projects" ON projects;
DROP POLICY IF EXISTS "Shared editors can update projects" ON projects;

-- SELECT: owner OR shared user
CREATE POLICY "projects_select" ON projects FOR SELECT
    USING (
        (select auth.uid()) = user_id
        OR EXISTS (
            SELECT 1 FROM project_shares
            WHERE project_shares.project_id = projects.id
              AND project_shares.shared_with_id = (select auth.uid())
        )
    );

-- INSERT: owner only
CREATE POLICY "projects_insert" ON projects FOR INSERT
    WITH CHECK ((select auth.uid()) = user_id);

-- UPDATE: owner OR shared editor
CREATE POLICY "projects_update" ON projects FOR UPDATE
    USING (
        (select auth.uid()) = user_id
        OR EXISTS (
            SELECT 1 FROM project_shares
            WHERE project_shares.project_id = projects.id
              AND project_shares.shared_with_id = (select auth.uid())
              AND project_shares.role = 'editor'
        )
    );

-- DELETE: owner only
CREATE POLICY "projects_delete" ON projects FOR DELETE
    USING ((select auth.uid()) = user_id);

-- =============================================
-- 2. tasks — merge using helper functions
-- =============================================

DROP POLICY IF EXISTS "Owner full access on tasks" ON tasks;
DROP POLICY IF EXISTS "Shared users can view tasks" ON tasks;
DROP POLICY IF EXISTS "Shared editors can update tasks" ON tasks;

-- SELECT: owner OR shared (has_project_access includes owner check)
CREATE POLICY "tasks_select" ON tasks FOR SELECT
    USING (has_project_access(project_id));

-- INSERT: owner only
CREATE POLICY "tasks_insert" ON tasks FOR INSERT
    WITH CHECK (is_project_owner(project_id));

-- UPDATE: owner OR shared editor (has_project_edit_access includes owner check)
CREATE POLICY "tasks_update" ON tasks FOR UPDATE
    USING (has_project_edit_access(project_id));

-- DELETE: owner only
CREATE POLICY "tasks_delete" ON tasks FOR DELETE
    USING (is_project_owner(project_id));

-- =============================================
-- 3. chat_history — merge using helper functions
-- =============================================

DROP POLICY IF EXISTS "Owner full access on chat_history" ON chat_history;
DROP POLICY IF EXISTS "Shared users can view chat_history" ON chat_history;

-- SELECT: owner OR shared (has_project_access includes owner check)
CREATE POLICY "chat_history_select" ON chat_history FOR SELECT
    USING (has_project_access(project_id));

-- INSERT: owner only
CREATE POLICY "chat_history_insert" ON chat_history FOR INSERT
    WITH CHECK (is_project_owner(project_id));

-- UPDATE: owner only
CREATE POLICY "chat_history_update" ON chat_history FOR UPDATE
    USING (is_project_owner(project_id));

-- DELETE: owner only
CREATE POLICY "chat_history_delete" ON chat_history FOR DELETE
    USING (is_project_owner(project_id));
