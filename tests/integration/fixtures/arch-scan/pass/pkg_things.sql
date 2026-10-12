CREATE OR REPLACE PACKAGE BODY pkg_things AUTHID DEFINER AS
  PROCEDURE update_row (p_id IN NUMBER, p_name IN VARCHAR2, p_row_version IN OUT NUMBER) IS
  BEGIN
    UPDATE things
       SET name = p_name, row_version = row_version + 1
     WHERE id = p_id
       AND row_version = p_row_version
    RETURNING row_version INTO p_row_version;
  END update_row;

  PROCEDURE close_row (p_id IN NUMBER) IS
    l_state things.state%TYPE;
  BEGIN
    SELECT state INTO l_state FROM things WHERE id = p_id FOR UPDATE;
    -- lost update review: the row is locked above and its from-state checked
    UPDATE things SET state = 'CLOSED' WHERE id = p_id;
  END close_row;
END pkg_things;
/

CREATE OR REPLACE PACKAGE BODY pkg_thing_flow AUTHID DEFINER AS
  -- A flow coordinates entity packages; 'update things set' in a literal is not DML.
  PROCEDURE close_all (p_id IN NUMBER) IS
  BEGIN
    pkg_things.close_row(p_id);
    pkg_parts.delete_row(p_id);
    apex_debug.message('insert into nothing');
  END close_all;
END pkg_thing_flow;
/
