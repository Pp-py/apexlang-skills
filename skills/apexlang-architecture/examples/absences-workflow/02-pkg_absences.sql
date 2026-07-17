-- 02-pkg_absences.sql — single write-path package for hr_absences.
-- Transitions are VERBS with a legal from-state guard, not raw `UPDATE status`.
-- Depends on: pkg_errors (00-) and table hr_absences (01-).

CREATE OR REPLACE PACKAGE pkg_absences AS
  /*
   * Only write path for hr_absences. No internal COMMIT.
   * Every transition validates its legal from-state. Errors in the -209xx band.
   */
  PROCEDURE create_row (p_employee_no IN VARCHAR2, p_absence_type IN VARCHAR2,
                        p_date_from IN DATE, p_date_to IN DATE);
  PROCEDURE approve    (p_absence_id IN NUMBER, p_approver IN VARCHAR2);
  PROCEDURE reject     (p_absence_id IN NUMBER, p_reason IN VARCHAR2);
  PROCEDURE cancel     (p_absence_id IN NUMBER, p_reason IN VARCHAR2, p_user IN VARCHAR2);
END pkg_absences;
/

CREATE OR REPLACE PACKAGE BODY pkg_absences AS

  PROCEDURE create_row (p_employee_no IN VARCHAR2, p_absence_type IN VARCHAR2,
                        p_date_from IN DATE, p_date_to IN DATE) IS
  BEGIN
    IF p_employee_no IS NULL OR p_absence_type IS NULL OR p_date_from IS NULL OR p_date_to IS NULL THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_absence_invalid_data,
        'Employee number, type and dates are required.');
    END IF;
    IF p_date_to < p_date_from THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_absence_invalid_dates,
        'The end date cannot be before the start date.');
    END IF;
    INSERT INTO hr_absences (employee_no, absence_type, date_from, date_to, status)
    VALUES (p_employee_no, p_absence_type, p_date_from, p_date_to, 'REQUESTED');
  END create_row;

  PROCEDURE approve (p_absence_id IN NUMBER, p_approver IN VARCHAR2) IS
    l_status hr_absences.status%TYPE;
  BEGIN
    SELECT status INTO l_status FROM hr_absences
     WHERE absence_id = p_absence_id AND cancelled_at IS NULL FOR UPDATE;
    IF l_status <> 'REQUESTED' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_absence_invalid_status,
        'Only an absence in REQUESTED status can be approved.');
    END IF;
    UPDATE hr_absences
       SET status = 'APPROVED', approved_by = p_approver, approved_at = SYSTIMESTAMP
     WHERE absence_id = p_absence_id;
    -- side effect (deduct quota, etc.) would live here, inside the package.
  END approve;

  PROCEDURE reject (p_absence_id IN NUMBER, p_reason IN VARCHAR2) IS
    l_status hr_absences.status%TYPE;
  BEGIN
    SELECT status INTO l_status FROM hr_absences
     WHERE absence_id = p_absence_id AND cancelled_at IS NULL FOR UPDATE;
    IF l_status <> 'REQUESTED' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_absence_invalid_status,
        'Only an absence in REQUESTED status can be rejected.');
    END IF;
    IF TRIM(p_reason) IS NULL THEN
      RAISE_APPLICATION_ERROR(pkg_errors.k_absence_invalid_data,
        'A rejection reason is required.');
    END IF;
    UPDATE hr_absences
       SET status = 'REJECTED', rejection_reason = TRIM(p_reason)
     WHERE absence_id = p_absence_id;
  END reject;

  PROCEDURE cancel (p_absence_id IN NUMBER, p_reason IN VARCHAR2, p_user IN VARCHAR2) IS
    l_status hr_absences.status%TYPE;
  BEGIN
    SELECT status INTO l_status FROM hr_absences
     WHERE absence_id = p_absence_id AND cancelled_at IS NULL FOR UPDATE;
    -- if it was APPROVED, the reversal of its effect (give back quota) would go here.
    UPDATE hr_absences
       SET cancelled_at = SYSTIMESTAMP, cancelled_by = p_user, cancel_reason = TRIM(p_reason)
     WHERE absence_id = p_absence_id;
  END cancel;

END pkg_absences;
/
