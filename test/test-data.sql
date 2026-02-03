-- Test data for backup/restore verification
-- This creates a simple schema with predictable data that can be verified after restore

-- Create a test table
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) NOT NULL UNIQUE,
    email VARCHAR(100) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create another table with a foreign key
CREATE TABLE IF NOT EXISTS posts (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    title VARCHAR(200) NOT NULL,
    content TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert test data
INSERT INTO users (username, email) VALUES
    ('alice', 'alice@example.com'),
    ('bob', 'bob@example.com'),
    ('charlie', 'charlie@example.com')
ON CONFLICT (username) DO NOTHING;

INSERT INTO posts (user_id, title, content) VALUES
    (1, 'Hello World', 'This is the first post by Alice.'),
    (1, 'PostgreSQL Tips', 'Some useful tips for PostgreSQL...'),
    (2, 'Docker Best Practices', 'How to structure your Docker setup...'),
    (3, 'Testing Backups', 'Always verify your backup and restore procedures!')
ON CONFLICT DO NOTHING;

-- Create a view for verification
CREATE OR REPLACE VIEW user_post_counts AS
SELECT u.username, COUNT(p.id) as post_count
FROM users u
LEFT JOIN posts p ON u.id = p.user_id
GROUP BY u.username;
