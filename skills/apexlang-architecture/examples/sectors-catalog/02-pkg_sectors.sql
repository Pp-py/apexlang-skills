-- 02-pkg_sectors.sql — single write-path package for hr_sectors.
-- Depends on: pkg_errors (00-) and table hr_sectors (01-).

CREATE OR REPLACE PACKAGE pkg_sectors AS
  /*
   * Only write path for hr_sectors.
   * No internal COMMIT (APEX commits on page submit).
   * Business exceptions via pkg_errors (-208xx band).
   */
  PROCEDURE create_row (p_code IN VARCHAR2, p_name IN VARCHAR2);
  PROCEDURE update_row (p_sector_id IN NUMBER, p_code IN VARCHAR2,
                        p_name IN VARCHAR2, p_active_flag IN VARCHAR2);
  PROCEDURE delete_row (p_sector_id IN NUMBER);
  -- IG adapter: routes :APEX$ROW_STATUS C/U/D to create_row/update_row/delete_row.
  PROCEDURE save_row (p_row_status  IN     VARCHAR2,
                      p_sector_id   IN OUT hr_sectors.sector_id%TYPE,
                      p_code        IN     hr_sectors.code%TYPE,
                      p_name        IN     hr_sectors.name%TYPE,
                      p_active_flag IN     hr_sectors.active_flag%TYPE);
END pkg_sectors;
/

CREATE OR REPLACE PACKAGE BODY pkg_sectors AS

  PROCEDURE create_row (p_code IN VARCHAR2, p_name IN VARCHAR2) IS
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
    VALUES (UPPER(TRIM(p_code)), TRIM(p_name), 'Y');
  END create_row;

  PROCEDURE update_row (p_sector_id IN NUMBER, p_code IN VARCHAR2,
                        p_name IN VARCHAR2, p_active_flag IN VARCHAR2) IS
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
           active_flag = NVL(p_active_flag,'Y')
     WHERE sector_id = p_sector_id;
  END update_row;

  PROCEDURE delete_row (p_sector_id IN NUMBER) IS
  BEGIN
    -- A real "in use" guard would check child FKs here and raise e_sector_in_use
    -- before deleting. Kept minimal for the example.
    DELETE FROM hr_sectors WHERE sector_id = p_sector_id;
  END delete_row;

  PROCEDURE save_row (p_row_status  IN     VARCHAR2,
                      p_sector_id   IN OUT hr_sectors.sector_id%TYPE,
                      p_code        IN     hr_sectors.code%TYPE,
                      p_name        IN     hr_sectors.name%TYPE,
                      p_active_flag IN     hr_sectors.active_flag%TYPE) IS
  BEGIN
    CASE p_row_status
      WHEN 'C' THEN
        create_row(p_code, p_name);
        SELECT sector_id INTO p_sector_id        -- return generated PK so the IG
          FROM hr_sectors                        -- finalizes the new row
         WHERE UPPER(code) = UPPER(TRIM(p_code));
      WHEN 'U' THEN update_row(p_sector_id, p_code, p_name, NVL(p_active_flag,'Y'));
      WHEN 'D' THEN delete_row(p_sector_id);
      ELSE NULL;                                 -- unchanged rows don't reach here
    END CASE;
  END save_row;

END pkg_sectors;
/
