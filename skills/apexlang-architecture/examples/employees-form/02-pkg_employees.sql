-- 02-pkg_employees.sql — the ONLY write path for hr_employees.
-- Architecture: apexlang-architecture/back-end-conventions.md
-- Recipe:       apexlang-architecture/recipes/form-page-to-package.md

CREATE OR REPLACE PACKAGE pkg_employees AS
  /*
   * Only write path for hr_employees.
   * No internal COMMIT (the caller / APEX commits).
   * Business exceptions via pkg_errors (-2081x codes).
   */
  PROCEDURE create_row (p_full_name IN  VARCHAR2,
                        p_email     IN  VARCHAR2,
                        p_sector_id IN  NUMBER,
                        p_hired_on  IN  DATE     DEFAULT NULL,
                        p_employee_id OUT NUMBER);

  PROCEDURE update_row (p_employee_id IN NUMBER,
                        p_full_name   IN VARCHAR2,
                        p_email       IN VARCHAR2,
                        p_sector_id   IN NUMBER,
                        p_hired_on    IN DATE DEFAULT NULL);

  -- Soft delete: inactivates (back-end-conventions.md section 6).
  PROCEDURE delete_row (p_employee_id IN NUMBER);
END pkg_employees;
/

CREATE OR REPLACE PACKAGE BODY pkg_employees AS

  -- Field-shape and business rules, in the one place the UI cannot bypass.
  PROCEDURE check_data (p_full_name IN VARCHAR2,
                        p_email     IN VARCHAR2,
                        p_sector_id IN NUMBER) IS
    l_cnt PLS_INTEGER;
  BEGIN
    IF TRIM(p_full_name) IS NULL OR TRIM(p_email) IS NULL OR p_sector_id IS NULL THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_employee_invalid_data,
        'Full name, email and sector are required.');
    END IF;

    IF INSTR(p_email, '@') = 0 THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_employee_invalid_data,
        'Email ' || TRIM(p_email) || ' is not a valid address.');
    END IF;

    SELECT COUNT(*) INTO l_cnt
      FROM hr_sectors
     WHERE sector_id = p_sector_id
       AND active_flag = 'Y';
    IF l_cnt = 0 THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_employee_sector_inactive,
        'That sector is inactive; pick an active one.');
    END IF;
  END check_data;

  -- p_employee_id excluded so an update does not collide with itself.
  PROCEDURE check_email_free (p_email       IN VARCHAR2,
                              p_employee_id IN NUMBER DEFAULT NULL) IS
    l_cnt PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO l_cnt
      FROM hr_employees
     WHERE UPPER(email) = UPPER(TRIM(p_email))
       AND (p_employee_id IS NULL OR employee_id <> p_employee_id);
    IF l_cnt > 0 THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_employee_email_duplicate,
        'An employee with email ' || LOWER(TRIM(p_email)) || ' already exists.');
    END IF;
  END check_email_free;

  PROCEDURE create_row (p_full_name IN  VARCHAR2,
                        p_email     IN  VARCHAR2,
                        p_sector_id IN  NUMBER,
                        p_hired_on  IN  DATE     DEFAULT NULL,
                        p_employee_id OUT NUMBER) IS
  BEGIN
    check_data(p_full_name, p_email, p_sector_id);
    check_email_free(p_email);

    INSERT INTO hr_employees (full_name, email, sector_id, hired_on)
    VALUES (TRIM(p_full_name), LOWER(TRIM(p_email)), p_sector_id,
            NVL(p_hired_on, TRUNC(SYSDATE)))
    RETURNING employee_id INTO p_employee_id;
  END create_row;

  PROCEDURE update_row (p_employee_id IN NUMBER,
                        p_full_name   IN VARCHAR2,
                        p_email       IN VARCHAR2,
                        p_sector_id   IN NUMBER,
                        p_hired_on    IN DATE DEFAULT NULL) IS
  BEGIN
    IF p_employee_id IS NULL THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_employee_invalid_data,
        'The employee to update was not identified.');
    END IF;

    check_data(p_full_name, p_email, p_sector_id);
    check_email_free(p_email, p_employee_id);

    UPDATE hr_employees
       SET full_name = TRIM(p_full_name),
           email     = LOWER(TRIM(p_email)),
           sector_id = p_sector_id,
           hired_on  = NVL(p_hired_on, hired_on)
     WHERE employee_id = p_employee_id;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_employee_invalid_data,
        'That employee no longer exists.');
    END IF;
  END update_row;

  PROCEDURE delete_row (p_employee_id IN NUMBER) IS
  BEGIN
    UPDATE hr_employees
       SET active_flag = 'N'
     WHERE employee_id = p_employee_id
       AND active_flag = 'Y';

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_employee_invalid_data,
        'That employee is already inactive or does not exist.');
    END IF;
  END delete_row;

END pkg_employees;
/
