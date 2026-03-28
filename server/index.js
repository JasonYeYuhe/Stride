require("dotenv").config();
const express = require("express");
const cors = require("cors");
const helmet = require("helmet");
const rateLimit = require("express-rate-limit");
const { requestLogger } = require("./logger");

const app = express();
const PORT = process.env.PORT || 3002;

// Security headers
app.use(helmet());

// Request logging
app.use(requestLogger);

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

// API v1 routes
const authRouter = require("./routes/auth");
const habitsRouter = require("./routes/habits");
const syncRouter = require("./routes/sync");

app.use("/v1/auth", authRouter);
app.use("/v1/habits", habitsRouter);
app.use("/v1/sync", syncRouter);

// Legacy routes (backwards compatible, same handlers)
app.use("/auth", authRouter);
app.use("/habits", habitsRouter);
app.use("/sync", syncRouter);

// Health check
app.get("/health", (req, res) => {
  res.json({ ok: true, version: "1.0.0", apiVersions: ["v1"], uptime: process.uptime() });
});

app.listen(PORT, () => {
  console.log(`Stride API running on port ${PORT}`);
});
