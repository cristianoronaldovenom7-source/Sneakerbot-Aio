const isPg = !!process.env.DATABASE_URL;

const pgBase = {
  client: 'pg',
  connection: {
    connectionString: process.env.DATABASE_URL,
    ssl: process.env.DATABASE_URL?.includes('rds.amazonaws.com')
      ? { rejectUnauthorized: false }
      : false
  },
  migrations: { directory: './db/migrations' },
  seeds: { directory: './db/seeds' },
  pool: { min: 2, max: Number(process.env.DB_POOL_MAX || 15), idleTimeoutMillis: 30000, acquireTimeoutMillis: 10000 }
};

const sqliteBase = {
  client: 'better-sqlite3',
  connection: { filename: './sneakerbot.db' },
  useNullAsDefault: true,
  pool: { min: 1, max: 1, afterCreate: (conn, done) => {
    try {
      conn.pragma('journal_mode = WAL');
      conn.pragma('synchronous = NORMAL');
      conn.pragma('busy_timeout = 5000');
    } catch (_) {}
    done(null, conn);
  } },
  migrations: { directory: './db/migrations' },
  seeds: { directory: './db/seeds' }
};

const config = {
  development: isPg ? pgBase : sqliteBase,
  production: isPg ? pgBase : sqliteBase,
  test: {
    client: 'better-sqlite3',
    connection: { filename: ':memory:' },
    useNullAsDefault: true,
    migrations: { directory: './db/migrations' },
    seeds: { directory: './db/seeds' }
  }
};

export default config;
