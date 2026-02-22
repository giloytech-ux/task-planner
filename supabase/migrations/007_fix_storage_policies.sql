-- Fix: Storage RLS policies have ambiguous 'name' column reference.
-- The EXISTS subquery joins projects (which has a 'name' column),
-- causing storage.foldername(name) to resolve to projects.name
-- instead of storage.objects.name. This blocks all shared user file access.

-- =============================================
-- 1. Fix SELECT policy for shared users
-- =============================================
DROP POLICY IF EXISTS "Shared users can read task files" ON storage.objects;

CREATE POLICY "Shared users can read task files"
    ON storage.objects FOR SELECT
    USING (
        bucket_id = 'task-files'
        AND EXISTS (
            SELECT 1 FROM project_shares ps
            JOIN projects p ON p.id = ps.project_id
            WHERE ps.shared_with_id = (select auth.uid())
              AND (storage.foldername(storage.objects.name))[1] = p.user_id::text
              AND (storage.foldername(storage.objects.name))[2] = ps.project_id::text
        )
    );

-- =============================================
-- 2. Fix INSERT policy for shared editors
-- =============================================
DROP POLICY IF EXISTS "Shared editors can upload task files" ON storage.objects;

CREATE POLICY "Shared editors can upload task files"
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'task-files'
        AND EXISTS (
            SELECT 1 FROM project_shares ps
            JOIN projects p ON p.id = ps.project_id
            WHERE ps.shared_with_id = (select auth.uid())
              AND ps.role = 'editor'
              AND (storage.foldername(storage.objects.name))[1] = p.user_id::text
              AND (storage.foldername(storage.objects.name))[2] = ps.project_id::text
        )
    );

-- =============================================
-- 3. Fix DELETE policy for shared editors
-- =============================================
DROP POLICY IF EXISTS "Shared editors can delete task files" ON storage.objects;

CREATE POLICY "Shared editors can delete task files"
    ON storage.objects FOR DELETE
    USING (
        bucket_id = 'task-files'
        AND EXISTS (
            SELECT 1 FROM project_shares ps
            JOIN projects p ON p.id = ps.project_id
            WHERE ps.shared_with_id = (select auth.uid())
              AND ps.role = 'editor'
              AND (storage.foldername(storage.objects.name))[1] = p.user_id::text
              AND (storage.foldername(storage.objects.name))[2] = ps.project_id::text
        )
    );
