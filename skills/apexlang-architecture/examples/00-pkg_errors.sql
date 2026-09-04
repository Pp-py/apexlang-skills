-- 00-pkg_errors.sql
-- Centralized error catalog: one reserved -20xxx band per domain, each code as a
-- CONSTANT and a named EXCEPTION. See apexlang-architecture/back-end-conventions.md §3.
-- A package of only constants/exceptions needs no body.

CREATE OR REPLACE PACKAGE pkg_errors AS

  -- Sectors band: -20800 .. -20809
  k_sector_code_duplicate CONSTANT NUMBER := -20800;
  k_sector_invalid_data   CONSTANT NUMBER := -20801;
  k_sector_in_use         CONSTANT NUMBER := -20802;

  e_sector_code_duplicate EXCEPTION;  PRAGMA EXCEPTION_INIT(e_sector_code_duplicate, -20800);
  e_sector_invalid_data   EXCEPTION;  PRAGMA EXCEPTION_INIT(e_sector_invalid_data,   -20801);
  e_sector_in_use         EXCEPTION;  PRAGMA EXCEPTION_INIT(e_sector_in_use,         -20802);

  -- Employees band: -20810 .. -20819
  k_employee_invalid_data     CONSTANT NUMBER := -20810;
  k_employee_email_duplicate  CONSTANT NUMBER := -20811;
  k_employee_sector_inactive  CONSTANT NUMBER := -20812;

  e_employee_invalid_data     EXCEPTION;  PRAGMA EXCEPTION_INIT(e_employee_invalid_data,    -20810);
  e_employee_email_duplicate  EXCEPTION;  PRAGMA EXCEPTION_INIT(e_employee_email_duplicate, -20811);
  e_employee_sector_inactive  EXCEPTION;  PRAGMA EXCEPTION_INIT(e_employee_sector_inactive, -20812);

  -- Absences band: -20900 .. -20909
  k_absence_invalid_data   CONSTANT NUMBER := -20900;
  k_absence_invalid_status CONSTANT NUMBER := -20901;
  k_absence_invalid_dates  CONSTANT NUMBER := -20902;

  e_absence_invalid_data   EXCEPTION;  PRAGMA EXCEPTION_INIT(e_absence_invalid_data,   -20900);
  e_absence_invalid_status EXCEPTION;  PRAGMA EXCEPTION_INIT(e_absence_invalid_status, -20901);
  e_absence_invalid_dates  EXCEPTION;  PRAGMA EXCEPTION_INIT(e_absence_invalid_dates,  -20902);

END pkg_errors;
/
