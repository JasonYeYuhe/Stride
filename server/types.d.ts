import "express";

declare module "express-serve-static-core" {
  interface Request {
    user?: {
      id: number;
      email: string;
      tier: string;
      created_at: string;
    };
    /** Set by auth.js attachSessionUser: the session was looked up (req.user is its result). */
    sessionChecked?: boolean;
    /** Parsed X-Stride-Client header, cached by lib/clientVersion.js (null = legacy client). */
    strideClient?: import("./lib/clientVersion").ClientInfo | null;
  }
}
