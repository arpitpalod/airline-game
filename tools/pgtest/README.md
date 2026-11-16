Local migration test. From this folder:

    npm i @electric-sql/pglite
    node run.mjs ../../supabase/migrations

It creates stand-ins for Supabase's roles and auth schema, runs every migration and prints the checks.
