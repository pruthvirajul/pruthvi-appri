const express = require('express');
const { Pool } = require('pg');
const dotenv = require('dotenv');
const cors = require('cors');

dotenv.config();

const app = express();
const port = process.env.PORT || 3405;

// CORS middleware with specific origins
app.use(cors({
  origin: [
    process.env.FRONTEND_URL,
    'http://127.0.0.1:5500',
    'http://44.223.23.145:8014',
    'http://44.223.23.145:8015',
    'http://localhost:5500'
  ]
}));
app.use(express.json());

const pool = new Pool({
  user: process.env.DB_USER || 'postgres',
  host: process.env.DB_HOST || 'postgres',
  database: process.env.DB_NAME || 'new_employee_db',
  password: process.env.DB_PASSWORD || 'admin123',
  port: process.env.DB_PORT || 5432,
  retry: {
    max: 5,
    timeout: 5000
  }
});

// Initialize database (create appraisals table if it doesn't exist)
async function initializeDatabase() {
  try {
    const tableCheck = await pool.query(`
      SELECT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_name = 'appraisals'
      );
    `);
    const tableExists = tableCheck.rows[0].exists;

    if (!tableExists) {
      console.log('Creating appraisals table...');
      await pool.query(`
        CREATE TABLE appraisals (
          id SERIAL PRIMARY KEY,
          emp_name VARCHAR(40) NOT NULL,
          emp_id VARCHAR(7) NOT NULL,
          task_name VARCHAR(40) NOT NULL,
          feedback TEXT NOT NULL,
          rating INTEGER NOT NULL,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          CONSTRAINT valid_emp_id CHECK (emp_id ~ '^[A-Z]{3}0[0-9]{3}$'),
          CONSTRAINT valid_rating CHECK (rating BETWEEN 1 AND 5)
        );
        CREATE INDEX idx_emp_id ON appraisals(emp_id);
        CREATE INDEX idx_created_at ON appraisals(created_at);
      `);
      console.log('Appraisals table created successfully.');
    } else {
      console.log('Appraisals table already exists.');
    }
  } catch (err) {
    console.error('Error initializing database:', {
      message: err.message,
      stack: err.stack,
      code: err.code,
      detail: err.detail
    });
    process.exit(1);
  }
}

// Connect to database with retry logic
async function connectWithRetry() {
  let retries = 5;
  while (retries) {
    try {
      const client = await pool.connect();
      client.release();
      console.log('Connected to PostgreSQL database');
      return;
    } catch (err) {
      console.error('Database connection error, retrying...', {
        message: err.message,
        code: err.code
      });
      retries--;
      await new Promise(res => setTimeout(res, 5000));
    }
  }
  console.error('Failed to connect to PostgreSQL after retries');
  process.exit(1);
}

// Health check endpoint
app.get('/api/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.status(200).json({ status: 'Database connection OK' });
  } catch (err) {
    console.error('Health check error:', {
      message: err.message,
      stack: err.stack,
      code: err.code
    });
    res.status(500).json({ error: 'Database connection failed', details: err.message });
  }
});

// Get all appraisals
app.get('/api/appraisals', async (req, res) => {
  try {
    let result;
    try {
      result = await pool.query('SELECT * FROM appraisals ORDER BY created_at DESC');
    } catch (err) {
      if (err.code === '42703') { // Undefined column
        console.warn('created_at column missing, falling back to query without ORDER BY');
        result = await pool.query('SELECT * FROM appraisals');
      } else if (err.code === '42P01') { // Undefined table
        console.error('Table "appraisals" does not exist');
        return res.status(500).json({ error: 'Table "appraisals" does not exist. Please initialize the database.' });
      } else {
        throw err;
      }
    }
    res.json(result.rows);
  } catch (err) {
    console.error('Error in GET /api/appraisals:', {
      message: err.message,
      stack: err.stack,
      code: err.code,
      detail: err.detail
    });
    res.status(500).json({ error: err.message || 'Server error' });
  }
});

// Create a new appraisal
app.post('/api/appraisals', async (req, res) => {
  const { empName, empId, taskName, feedback, rating } = req.body;

  if (!empName || !empId || !taskName || !feedback || !rating) {
    return res.status(400).json({ error: 'All fields are required' });
  }

  try {
    const result = await pool.query(
      'INSERT INTO appraisals (emp_name, emp_id, task_name, feedback, rating) VALUES ($1, $2, $3, $4, $5) RETURNING *',
      [empName, empId, taskName, feedback, rating]
    );
    res.status(201).json(result.rows[0]);
  } catch (err) {
    console.error('Error in POST /api/appraisals:', {
      message: err.message,
      stack: err.stack,
      code: err.code,
      detail: err.detail
    });
    res.status(500).json({ error: err.message || 'Server error' });
  }
});

// Start server after DB connection is established
async function startServer() {
  try {
    await connectWithRetry();
    await initializeDatabase();
    
    app.listen(port, () => {
      console.log(`Server running on port ${port}`);
    });
  } catch (err) {
    console.error('Failed to start server:', err);
    process.exit(1);
  }
}

startServer();
