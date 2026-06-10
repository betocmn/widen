-- Sample test database for Widen (see README).
-- Usage:
--   createdb widen_test
--   psql -d widen_test -f scripts/sample_db.sql

CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  email TEXT NOT NULL,
  name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE orders (
  id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id),
  total_cents INTEGER NOT NULL,
  status TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO users (email, name, created_at) VALUES
('alice@example.com', 'Alice', now() - interval '10 days'),
('bob@example.com', 'Bob', now() - interval '5 days'),
('carla@example.com', 'Carla', now() - interval '1 day');

INSERT INTO orders (user_id, total_cents, status, created_at) VALUES
(1, 2500, 'paid', now() - interval '9 days'),
(1, 4500, 'paid', now() - interval '4 days'),
(2, 1200, 'refunded', now() - interval '3 days'),
(3, 9900, 'paid', now() - interval '1 day');
