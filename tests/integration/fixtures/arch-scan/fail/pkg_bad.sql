CREATE OR REPLACE PACKAGE BODY pkg_things AUTHID DEFINER AS
  PROCEDURE rename_row (p_id IN NUMBER, p_name IN VARCHAR2) IS
  BEGIN
    UPDATE things SET name = p_name WHERE id = p_id;
  END rename_row;

  PROCEDURE close_row (p_id IN NUMBER) IS
  BEGIN
    -- lost update review: two lines above the statement does not count
    NULL;
    UPDATE things SET state = 'CLOSED' WHERE id = p_id;
  END close_row;
END pkg_things;
/

CREATE OR REPLACE PACKAGE BODY pkg_thing_flow AUTHID DEFINER AS
  PROCEDURE close_all (p_id IN NUMBER) IS
  BEGIN
    pkg_things.close_row(p_id);
    DELETE FROM parts WHERE thing_id = p_id;
    INSERT INTO thing_log (thing_id) VALUES (p_id);
  END close_all;
END pkg_thing_flow;
/
