-- 02-pkg_sectors.sql — single write-path package for hr_sectors.
-- Depends on: pkg_errors (00-) and table hr_sectors (01-).

CREATE OR REPLACE PACKAGE pkg_sectors AUTHID DEFINER AS
  /*
   * Only write path for hr_sectors.
   * No internal COMMIT (APEX commits on page submit).
   * Business exceptions via pkg_errors (-208xx band).
   */
  PROCEDURE create_row (p_code IN VARCHAR2, p_name IN VARCHAR2,
                        p_sector_id OUT hr_sectors.sector_id%TYPE);
  -- p_row_version: the version the grid loaded (back-end-conventions.md section 7);
  -- IN OUT so the caller keeps the bumped version.
  PROCEDURE update_row (p_sector_id IN NUMBER, p_code IN VARCHAR2,
                        p_name IN VARCHAR2, p_active_flag IN VARCHAR2,
                        p_row_version IN OUT hr_sectors.row_version%TYPE);
  PROCEDURE delete_row (p_sector_id IN NUMBER,
                        p_row_version IN hr_sectors.row_version%TYPE);
  -- IG adapter: routes :APEX$ROW_STATUS C/U/D to create_row/update_row/delete_row.
  -- p_row_version is IN OUT: the grid keeps the new version and can save the row again.
  PROCEDURE save_row (p_row_status  IN     VARCHAR2,
                      p_sector_id   IN OUT hr_sectors.sector_id%TYPE,
                      p_code        IN     hr_sectors.code%TYPE,
                      p_name        IN     hr_sectors.name%TYPE,
                      p_active_flag IN     hr_sectors.active_flag%TYPE,
                      p_row_version IN OUT hr_sectors.row_version%TYPE);
END pkg_sectors;
/

CREATE OR REPLACE PACKAGE BODY pkg_sectors AS

  PROCEDURE create_row (p_code IN VARCHAR2, p_name IN VARCHAR2,
                        p_sector_id OUT hr_sectors.sector_id%TYPE) IS
    l_cnt PLS_INTEGER;
  BEGIN
    IF TRIM(p_code) IS NULL OR TRIM(p_name) IS NULL THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_sector_invalid_data,
        'Code and name are required.');
    END IF;
    SELECT COUNT(*) INTO l_cnt FROM hr_sectors
     WHERE UPPER(code) = UPPER(TRIM(p_code));
    IF l_cnt > 0 THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_sector_code_duplicate,
        'A sector with code ' || TRIM(p_code) || ' already exists.');
    END IF;
    INSERT INTO hr_sectors (code, name, active_flag)
    VALUES (UPPER(TRIM(p_code)), TRIM(p_name), 'Y')
    RETURNING sector_id INTO p_sector_id;   -- never re-SELECT by a mutable column
  END create_row;

  PROCEDURE update_row (p_sector_id IN NUMBER, p_code IN VARCHAR2,
                        p_name IN VARCHAR2, p_active_flag IN VARCHAR2,
                        p_row_version IN OUT hr_sectors.row_version%TYPE) IS
    l_cnt PLS_INTEGER;
  BEGIN
    IF TRIM(p_code) IS NULL OR TRIM(p_name) IS NULL THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_sector_invalid_data,
        'Code and name are required.');
    END IF;
    -- uniqueness, excluding the row being updated
    SELECT COUNT(*) INTO l_cnt FROM hr_sectors
     WHERE UPPER(code) = UPPER(TRIM(p_code))
       AND sector_id <> p_sector_id;
    IF l_cnt > 0 THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_sector_code_duplicate,
        'A sector with code ' || TRIM(p_code) || ' already exists.');
    END IF;
    UPDATE hr_sectors
       SET code = UPPER(TRIM(p_code)),
           name = TRIM(p_name),
           active_flag = NVL(p_active_flag,'Y'),
           row_version = row_version + 1             -- bumped in the same statement
     WHERE sector_id = p_sector_id
       AND row_version = p_row_version               -- the guard
    RETURNING row_version INTO p_row_version;
    IF SQL%ROWCOUNT = 0 THEN
      -- The row is gone, or someone saved first: both are a conflict to the user.
      RAISE_APPLICATION_ERROR(pkg_errors.k_row_changed,
        'This record was changed by someone else since you opened it. Reload and try again.');
    END IF;
  END update_row;

  PROCEDURE delete_row (p_sector_id IN NUMBER,
                        p_row_version IN hr_sectors.row_version%TYPE) IS
  BEGIN
    -- A catalog is soft-deleted (back-end-conventions.md section 6). A hard DELETE
    -- here would hit hr_employees_sector_fk and surface as a raw ORA-02292.
    UPDATE hr_sectors
       SET active_flag = 'N',
           row_version = row_version + 1
     WHERE sector_id = p_sector_id
       AND row_version = p_row_version;
    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_row_changed,
        'This record was changed by someone else since you opened it. Reload and try again.');
    END IF;
    -- Section 6 also asks that inactivation be refused while the sector is still
    -- referenced. That guard needs the child table, which belongs to the
    -- employees-form slice, so this standalone slice cannot compile it:
    --   SELECT COUNT(*) INTO l_cnt FROM hr_employees WHERE sector_id = p_sector_id;
    --   IF l_cnt > 0 THEN RAISE_APPLICATION_ERROR(pkg_errors.k_sector_in_use, ...);
  END delete_row;

  PROCEDURE save_row (p_row_status  IN     VARCHAR2,
                      p_sector_id   IN OUT hr_sectors.sector_id%TYPE,
                      p_code        IN     hr_sectors.code%TYPE,
                      p_name        IN     hr_sectors.name%TYPE,
                      p_active_flag IN     hr_sectors.active_flag%TYPE,
                      p_row_version IN OUT hr_sectors.row_version%TYPE) IS
  BEGIN
    CASE p_row_status
      WHEN 'C' THEN
        create_row(p_code, p_name, p_sector_id);  -- OUT: the IG finalizes the new row
        p_row_version := 1;                        -- the column default
      WHEN 'U' THEN update_row(p_sector_id, p_code, p_name, NVL(p_active_flag,'Y'), p_row_version);
      WHEN 'D' THEN delete_row(p_sector_id, p_row_version);
      ELSE NULL;                                 -- unchanged rows don't reach here
    END CASE;
  END save_row;

END pkg_sectors;
/
