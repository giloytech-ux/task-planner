-- Add 'assigned' column to tasks table
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS assigned TEXT NOT NULL DEFAULT '';
