-- Enable Supabase Realtime for tasks and projects tables.
-- Required for postgres_changes subscriptions to deliver events.
-- If already configured via the Supabase Dashboard, these are safe no-ops.

DO $$
BEGIN
    -- Add tasks to realtime publication if not already present
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND tablename = 'tasks'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE tasks;
    END IF;

    -- Add projects to realtime publication if not already present
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND tablename = 'projects'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE projects;
    END IF;
END $$;
