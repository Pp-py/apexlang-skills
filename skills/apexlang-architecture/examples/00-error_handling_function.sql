-- 00-error_handling_function.sql
-- Application-level Error Handling Function (EHF). For business errors raised via
-- RAISE_APPLICATION_ERROR (-20000..-20999) it shows our friendly message and drops
-- the "ORA-20xxx:" prefix, so package errors reach the user as clean text.
--
-- This is what makes the example the CORRECT end state. Without it, the package still
-- raises correctly but the UI leaks "ORA-20800: ..." — the exact defect apex-sentinel's
-- editable-ig check flags. See back-end-conventions.md §3.
--
-- Register it AFTER creating it:
--   Shared Components -> Application Definition Attributes -> Error Handling ->
--   Error Handling Function = APEX_ERROR_HANDLER
-- (or declare it in the application-level .apx if your APEXlang export includes app attrs).

CREATE OR REPLACE FUNCTION apex_error_handler (
    p_error IN apex_error.t_error
) RETURN apex_error.t_error_result
IS
    l_result apex_error.t_error_result;
BEGIN
    l_result := apex_error.init_error_result(p_error => p_error);

    IF p_error.ora_sqlcode BETWEEN -20999 AND -20000 THEN
        -- friendly text only, no ORA- prefix
        l_result.message          := apex_error.get_first_ora_error_text(p_error => p_error);
        l_result.additional_info  := NULL;
        l_result.display_location  := apex_error.c_inline_in_notification;
    END IF;

    RETURN l_result;
END apex_error_handler;
/
