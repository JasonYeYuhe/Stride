/**
 * Simple request logger middleware.
 * Logs method, path, status code, and response time.
 */
function requestLogger(req, res, next) {
  const start = Date.now();
  const { method, originalUrl } = req;

  res.on("finish", () => {
    const duration = Date.now() - start;
    const status = res.statusCode;
    const level = status >= 500 ? "ERROR" : status >= 400 ? "WARN" : "INFO";
    const timestamp = new Date().toISOString();
    console.log(
      `[${timestamp}] ${level} ${method} ${originalUrl} ${status} ${duration}ms`,
    );
  });

  next();
}

module.exports = { requestLogger };
