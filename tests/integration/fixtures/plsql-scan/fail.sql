CREATE OR REPLACE PACKAGE pkg_bad AS
  PROCEDURE run (p_name IN VARCHAR2, p_sql IN VARCHAR2);
END pkg_bad;
/
CREATE OR REPLACE PACKAGE BODY pkg_bad AS
  PROCEDURE run (p_name IN VARCHAR2, p_sql IN VARCHAR2) IS
    l_sql VARCHAR2(4000);
    l_cur SYS_REFCURSOR;
    l_c   INTEGER;
    l_ctx apex_exec.t_context;
  BEGIN
    EXECUTE IMMEDIATE 'delete from t where name = ''' || p_name || '''';
    l_sql := 'select * from t where name = ''' || p_name || '''';
    OPEN l_cur FOR l_sql;
    -- dynamic sql review: a review comment does not excuse a concatenated value
    EXECUTE IMMEDIATE 'drop table ' || p_name;
    EXECUTE IMMEDIATE p_sql;
    DBMS_SQL.PARSE(l_c, p_sql, DBMS_SQL.NATIVE);
    l_ctx := apex_exec.open_query_context(p_location => apex_exec.c_location_local_db,
                                          p_sql_query => 'select * from t where x = ' || p_name);
  END run;
END pkg_bad;
/
