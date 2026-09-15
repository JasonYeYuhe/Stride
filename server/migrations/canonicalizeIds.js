// @ts-check

/**
 * Store every entity id in UPPER case. Idempotent; runs inside migrateIfNeeded at startup.
 *
 * Why. Swift's UUID.uuidString is upper case, and every id the iOS/macOS app sends is
 * upper case. Ids this server generated itself — seed-demo.js and the REST create routes,
 * via Node's crypto.randomUUID() — are lower case. The primary keys are plain TEXT with
 * the default BINARY collation, so "abc" and "ABC" are different rows.
 *
 * That seam broke the App Review demo account in both directions:
 * - clients compared ids as raw strings, so the demo account's lower-case entries matched
 *   no habit and a full pull deleted the device's history (fixed client-side in 1.2.3,
 *   SyncReconciler.canonicalID);
 * - once a client normalises those ids, its next push sends them upper case, and
 *   `INSERT ... ON CONFLICT(id)` finds no conflict — so every habit and entry in the demo
 *   account would be inserted a second time.
 * Upper-casing the stored ids closes both. It also fixes already-shipped clients without a
 * new build: their raw string comparisons match once the server stores upper case.
 *
 * Deliberately conservative, because a migration that throws here crash-loops the server
 * (v2's did). If any lower-case id already has an upper-case twin, nothing is changed: the
 * clients now compare ids case-insensitively, so leaving duplicates is untidy, not broken,
 * whereas merging them automatically is exactly the kind of clever that goes wrong at startup.
 *
 * Must run inside a transaction: habit_entries.habit_id references habits(id) with no
 * ON UPDATE CASCADE, so re-keying a habit violates the constraint until its entries follow,
 * and the check is deferred to COMMIT.
 *
 * @param {import('better-sqlite3').Database} db
 * @returns {{ lowercase: number, twins: number, changed: boolean }}
 */
function canonicalizeIds(db) {
  if (!db.inTransaction) {
    throw new Error("canonicalizeIds must run inside a transaction (foreign-key checks are deferred to COMMIT)");
  }

  /** @param {string} sql */
  const count = (sql) => /** @type {{ n: number }} */ (db.prepare(sql).get()).n;

  const lowercase = count(`SELECT
      (SELECT count(*) FROM habits WHERE id <> upper(id))
    + (SELECT count(*) FROM habits WHERE group_id IS NOT NULL AND group_id <> upper(group_id))
    + (SELECT count(*) FROM habit_entries WHERE id <> upper(id) OR habit_id <> upper(habit_id))
    + (SELECT count(*) FROM habit_groups WHERE id <> upper(id))
    + (SELECT count(*) FROM deletion_tombstones WHERE entity_id <> upper(entity_id)) AS n`);
  if (lowercase === 0) return { lowercase: 0, twins: 0, changed: false };

  const twins = count(`SELECT
      (SELECT count(*) FROM habits a JOIN habits b ON b.id = upper(a.id) AND b.id <> a.id)
    + (SELECT count(*) FROM habit_entries a JOIN habit_entries b ON b.id = upper(a.id) AND b.id <> a.id)
    + (SELECT count(*) FROM habit_groups a JOIN habit_groups b ON b.id = upper(a.id) AND b.id <> a.id) AS n`);
  if (twins > 0) {
    console.warn(
      `[migrate] ${lowercase} id values are not upper case, but ${twins} already have an upper-case twin; ` +
        "leaving every id as it is (clients compare ids case-insensitively).",
    );
    return { lowercase, twins, changed: false };
  }

  db.pragma("defer_foreign_keys = ON");
  db.exec(`
    UPDATE habits SET id = upper(id) WHERE id <> upper(id);
    UPDATE habit_entries SET habit_id = upper(habit_id) WHERE habit_id <> upper(habit_id);
    UPDATE habit_entries SET id = upper(id) WHERE id <> upper(id);
    UPDATE habit_groups SET id = upper(id) WHERE id <> upper(id);
    UPDATE habits SET group_id = upper(group_id) WHERE group_id IS NOT NULL AND group_id <> upper(group_id);
    UPDATE deletion_tombstones SET entity_id = upper(entity_id) WHERE entity_id <> upper(entity_id);
  `);
  console.log(`[migrate] upper-cased ${lowercase} id values`);
  return { lowercase, twins: 0, changed: true };
}

module.exports = { canonicalizeIds };
