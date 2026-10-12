-- Near-misses: every dynamic statement here runs a text the scan can prove safe or reviewed.
CREATE OR REPLACE PACKAGE pkg_report AUTHID CURRENT_USER AS
  PROCEDURE run (p_table IN VARCHAR2, p_id IN NUMBER, p_sql IN VARCHAR2);
END pkg_report;
/
CREATE OR REPLACE PACKAGE BODY pkg_report AS
  PROCEDURE run (p_table IN VARCHAR2, p_id IN NUMBER, p_sql IN VARCHAR2) IS
    l_sql   VARCHAR2(4000);
    l_where VARCHAR2(200) := ' where id = :id';
    l_cur   SYS_REFCURSOR;
    l_c     INTEGER;
  BEGIN
    EXECUTE IMMEDIATE 'delete from t_log where id = :1' USING p_id;
    EXECUTE IMMEDIATE q'[update t_log set note = 'a || b' where id = :1]' USING p_id;
    l_sql := 'select count(*) from ' || DBMS_ASSERT.SQL_OBJECT_NAME(p_table) || l_where;
    EXECUTE IMMEDIATE l_sql INTO l_c USING p_id;
    -- a comment with || p_table is not code
    OPEN l_cur FOR SELECT id FROM t_log WHERE id = p_id;
    OPEN l_cur FOR 'select id from t_log where id = :1' USING p_id;
    l_c := DBMS_SQL.OPEN_CURSOR;
    DBMS_SQL.PARSE(l_c, 'select 1 from dual', DBMS_SQL.NATIVE);
    -- dynamic sql review: p_sql comes from the admin-only report builder, validated by pkg_report_admin
    EXECUTE IMMEDIATE p_sql;
  END run;
END pkg_report;
/
