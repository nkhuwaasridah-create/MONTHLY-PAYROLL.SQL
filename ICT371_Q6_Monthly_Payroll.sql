-- ICT371 Advanced Database - Question 6: Monthly Payroll

-- ==== Setup ====
-- Run top to bottom in psql / pgAdmin (PostgreSQL 11 or later).
-- Scheduling in part (g) needs the pg_cron extension.
DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- ==== (a) Database and seed data ====
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT chk_month_start CHECK (EXTRACT(DAY FROM pay_month) = 1),
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Anna Mutale',    8000.00, 1500.00, 1200.00, TRUE),
    ('Bwalya Chisha',  6500.00, 1000.00,  900.00, TRUE),
    ('Cosmas Daka',    9500.00, 2000.00, 1500.00, TRUE),
    ('Dorothy Ngosa',  7000.00, 1200.00, 1000.00, TRUE),   -- becomes inactive below
    ('Elias Mwewa',    5000.00,  500.00,  600.00, FALSE);  -- inactive from the start

-- Payroll rows for two months are created through the procedure in part (c).

-- ==== (b) Function: fn_net_pay ====
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC AS $$
DECLARE
    v_net NUMERIC(12,2);
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$ LANGUAGE plpgsql;

SELECT fn_net_pay(1);                -- 8000 + 1500 - 1200 = 8300.00
-- SELECT fn_net_pay(99);            -- error: unknown employee

-- ==== (c) Procedure: pr_process_payroll ====
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    rec   RECORD;
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'Month must be the first date of a month (got %)', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary + allowance AS gross
        FROM employees
        WHERE active
        ORDER BY employee_id
    LOOP
        -- Raises if net pay is invalid, which aborts the whole call
        v_net := fn_net_pay(rec.employee_id);

        -- Existing employee/month rows are left unchanged
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, rec.gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- ==== (d) Trigger: salary audit ====
CREATE OR REPLACE FUNCTION trg_fn_salary_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)   -- only a real change
EXECUTE FUNCTION trg_fn_salary_audit();

-- Seed payroll: two months, then one employee becomes inactive
CALL pr_process_payroll('2026-09-01');
CALL pr_process_payroll('2026-10-01');
CALL pr_process_payroll('2026-10-01');             -- rerun: nothing changes
SELECT COUNT(*) FROM payroll;                      -- 8 rows (4 active x 2 months)

UPDATE employees SET active = FALSE WHERE employee_id = 4;
CALL pr_process_payroll('2026-11-01');             -- employee 4 is now skipped

-- Trigger tests
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;   -- audited
UPDATE employees SET allowance = 1600    WHERE employee_id = 1;   -- not audited
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;   -- same value: not audited
SELECT * FROM salary_audit;                        -- exactly one row

-- Error tests
-- CALL pr_process_payroll('2026-11-15');          -- error: not a month start
-- UPDATE employees SET deduction = 99999 WHERE employee_id = 2;
-- CALL pr_process_payroll('2026-12-01');          -- error: whole call fails, no rows added

-- ==== (e) View: v_payroll_report ====
-- Plain JOIN with no "active" filter, so history of inactive employees is kept.
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT p.payroll_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- ==== (f) Index ====
-- Justification: the existing unique index on (employee_id, pay_month) starts
-- with employee_id, so it cannot efficiently answer "all employees in one
-- month". An index on pay_month alone supports that report and is not a
-- duplicate of the unique index.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

SET enable_seqscan = off;   -- demo only: tiny tables would otherwise use a seq scan
EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = '2026-10-01';
RESET enable_seqscan;

-- ==== (g) Scheduled job: monthly payroll ====
-- 02:00 on the first day of each month, for the first date of the previous month
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'process_payroll_monthly',
    '0 2 1 * *',
    $$CALL pr_process_payroll(
          (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$
);

-- Inspect the job
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'process_payroll_monthly';

-- Inspect its run history
SELECT jobid, runid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'process_payroll_monthly')
ORDER BY start_time DESC
LIMIT 10;
