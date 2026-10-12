CREATE OR REPLACE PACKAGE BODY pkg_open AUTHID DEFINER AS
  PROCEDURE p IS BEGIN apex_debug.message('never closed); END p;
END pkg_open;
/
