require("dotenv").config();
const express = require("express");
const cors = require("cors");
const helmet = require("helmet");
const rateLimit = require("express-rate-limit");

const app = express();
const PORT = process.env.PORT || 3002;

// Security headers
app.use(helmet());

// Global rate limit: 100 requests per 15 minutes per IP
const globalLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: "Too many requests, please try again later" },
});
app.use(globalLimiter);

const allowedOrigins = new Set([
  process.env.FRONTEND_ORIGIN || "https://stride.colorarchive.me",
  ...(process.env.NODE_ENV !== "production"
    ? ["http://localhost:3000", "http://127.0.0.1:3000"]
    : []),
]);

app.use(
  cors({
    origin(origin, callback) {
      // Allow requests with no origin (mobile apps, curl)
      if (!origin || allowedOrigins.has(origin)) {
        return callback(null, true);
      }
      return callback(new Error("Not allowed by CORS"));
    },
    methods: ["GET", "POST", "PUT", "DELETE"],
    credentials: true,
  }),
);

app.use(express.json({ limit: "10kb" }));

// Routes
app.use("/auth", require("./routes/auth"));
app.use("/habits", require("./routes/habits"));
app.use("/sync", require("./routes/sync"));

// Health check
app.get("/health", (req, res) => {
  res.json({ ok: true, uptime: process.uptime() });
});

app.listen(PORT, () => {
  console.log(`Stride API running on port ${PORT}`);
});
