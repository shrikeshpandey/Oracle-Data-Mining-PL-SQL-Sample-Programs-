Rem
Rem $Header: dmardemo.sql 29-dec-2006.10:30:34 dmukhin Exp $
Rem
Rem dmardemo.sql
Rem
Rem Copyright (c) 2003, 2006, Oracle. All rights reserved.  
Rem
Rem    NAME
Rem      dmardemo.sql - Sample program for the DBMS_DATA_MINING package.
Rem
Rem    DESCRIPTION
Rem      This script creates an association model
Rem      using the Apriori algorithm
Rem      and data in the SH (Sales History) schema in the RDBMS. 
Rem
Rem    NOTES
Rem     
Rem
Rem    MODIFIED   (MM/DD/YY) 
Rem    dmukhin     12/13/06 - bug 5557333: AR scoping
Rem    ktaylor     07/11/05 - minor edits to comments
Rem    ramkrish    03/04/05 - 4222328: fix sales_trans queries for dupl custids
Rem    jcjeon      01/18/05 - add column format 
Rem    ramkrish    09/16/04 - add data analysis and comments/cleanup
Rem    ramkrish    07/30/04 - lrg 1726339 - comment out itemsetid
Rem                           hash-based group by no longer guarantees
Rem                           ordered itemset ids
Rem    xbarr       06/25/04 - xbarr_dm_rdbms_migration
Rem    mmcracke    12/11/03 - Remove RuleID from results display 
Rem    ramkrish    10/20/03 - ramkrish_txn109085
Rem    ramkrish    10/02/03 - Creation
  
SET serveroutput ON
SET trimspool ON  
SET pages 10000
SET linesize 140
SET echo ON

-----------------------------------------------------------------------
--                            SAMPLE PROBLEM
-----------------------------------------------------------------------
-- Find the associations between items bought by customers

-----------------------------------------------------------------------
--                            SET UP AND ANALYZE THE DATA
-----------------------------------------------------------------------

-- Cleanup old dataset for repeat runs
BEGIN EXECUTE IMMEDIATE 'DROP VIEW sales_trans_cust';
EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP VIEW sales_trans_cust_ar';
EXCEPTION WHEN OTHERS THEN NULL; END;
/

-------
-- DATA
-------
-- The data for this sample is composed from a small subset of
-- sales transactions in the SH schema - listing the (multiple)
-- items bought by a set of customers with ids in the range
-- 100001-104500. Note that this data is based on customer id,
-- not basket id (as in the case of true market basket data).
-- But in either case, it is useful to remove duplicate occurrences
-- (e.g. customer buys two cans of milk in the same visit, or buys
-- boxes of the same cereal in multiple, independent visits)
-- of items per customer or per basket, since what we care about
-- is just the presence/absence of a given item per customer/basket
-- id to compute the rules. Hence the DISTINCT in the view definition.
--
CREATE VIEW sales_trans_cust AS
SELECT DISTINCT cust_id, prod_name, 1 has_it
FROM (SELECT a.cust_id, b.prod_name
        FROM sh.sales a, sh.products b
       WHERE a.prod_id = b.prod_id AND
             a.cust_id between 100001 AND 104500)
ORDER BY cust_id, prod_name;

-----------
-- ANALYSIS
-----------
-- Association Rules in ODM works best on sparse data - i.e. data where
-- the average number of attributes/items associated with a given case is
-- a small percentage of the total number of possible attributes/items.
-- This is true of most market basket datasets where an average customer
-- purchases only a small subset of items from a fairly large inventory
-- in the store.
--
-- This section provides a rough outline of the analysis to be performed
-- on data used for Association Rules model build.
--
-- 1. Compute the cardinality of customer id and product (940, 11)
SELECT COUNT(DISTINCT cust_id) cc, COUNT(DISTINCT prod_name) cp
  FROM sales_trans_cust;

-- 2. Compute the density of data (27.08)
column density format a18
SELECT TO_CHAR((100 * ct)/(cc * cp), 99.99) density
  FROM (SELECT COUNT(DISTINCT cust_id) cc,
               COUNT(DISTINCT prod_name) cp,
               COUNT(*) ct
          FROM sales_trans_cust);

-- 3. Common items are candidates for removal during model build, because
--    if a majority of customers have bought those items, the resulting
--    rules do not have much value. Find out most common items. For example,
--    the query shown below determines that Mouse_Pad is most common (303).
--
--    Since the dataset is small, we will skip common item removal.
--
column prod_name format a80
SELECT prod_name, count(prod_name) cnt
  FROM sales_trans_cust
GROUP BY prod_name
ORDER BY cnt DESC, prod_name DESC;

-- 4. Compute the average number of products purchased per customer (2.98)
--    3 out of 11 corresponds to the density we computed earlier.
--
column avg_num_prod format a16
SELECT TO_CHAR(AVG(cp), 999.99) avg_num_prod
  FROM (SELECT COUNT(prod_name) cp
          FROM sales_trans_cust
        GROUP BY cust_id);

-- 5. For sparse data, it is common to have a density below 1%, and
--    AR typically performs well with sparse data. The above dataset
--    is moderately dense (because of the aggregation), and we have
--    to tune the AR parameters in accordance. Start with
--
--    - Min Support = 0.1
--    - Min Confidence = 0.1
--    - Max Rule Length (i.e. Items) = 3

-- 6. Market basket or sales datasets are transactional in nature,
--    and form dimension tables in a typical DW. We present such
--    transactional data to the API using an Object View that contains
--    a nested table column holding a collection of items that
--    correspond to a given customer id.
--
CREATE VIEW sales_trans_cust_ar AS
SELECT cust_id,
       CAST(COLLECT(DM_Nested_Numerical(
         prod_name, has_it))
       AS DM_Nested_Numericals) custprods
  FROM sales_trans_cust
GROUP BY cust_id;

-----------------------------------------------------------------------
--                            BUILD THE MODEL
-----------------------------------------------------------------------

--------------------------------
-- PREPARE BUILD (TRAINING) DATA
--
-- Data for AR modeling may need binning if it contains numerical
-- data, and categorical data with high cardinality. See dmabdemo.sql
-- for an example on quantile binning.

-------------------
-- SPECIFY SETTINGS
--
-- Cleanup old settings table for repeat runs
BEGIN EXECUTE IMMEDIATE 'DROP TABLE ar_sh_sample_settings';
EXCEPTION WHEN OTHERS THEN NULL; END;
/

-- The default (and only) algorithm for association rules is
-- Apriori AR. However, we need a settings table because we
-- intend to override the default Min Support, Min Confidence,
-- Max items
-- 
set echo off
CREATE TABLE ar_sh_sample_settings (
  setting_name  VARCHAR2(30),
  setting_value VARCHAR2(30));
set echo on

BEGIN       
  INSERT INTO ar_sh_sample_settings VALUES
  (dbms_data_mining.asso_min_support,0.1);
  INSERT INTO ar_sh_sample_settings VALUES
  (dbms_data_mining.asso_min_confidence,0.1);
  INSERT INTO ar_sh_sample_settings VALUES
  (dbms_data_mining.asso_max_rule_length,3);
  COMMIT;
END;
/

---------------------
-- CREATE A NEW MODEL
--
-- Cleanup old model with same name for repeat runs
BEGIN DBMS_DATA_MINING.DROP_MODEL('AR_SH_sample');
EXCEPTION WHEN OTHERS THEN NULL; END;
/

-- Build a new AR model
BEGIN
  DBMS_DATA_MINING.CREATE_MODEL(
    model_name          => 'AR_SH_sample',
    mining_function     => DBMS_DATA_MINING.ASSOCIATION,
    data_table_name     => 'sales_trans_cust_ar',
    case_id_column_name => 'cust_id',
    settings_table_name => 'ar_sh_sample_settings');
END;
/

-------------------------
-- DISPLAY MODEL SETTINGS
--
column setting_name format a30
column setting_value format a30
SELECT setting_name, setting_value
  FROM TABLE(DBMS_DATA_MINING.GET_MODEL_SETTINGS('AR_SH_sample'))
ORDER BY setting_name;

--------------------------
-- DISPLAY MODEL SIGNATURE
-- 
-- NOT APPLICABLE
-- The model signature is applicable only for predictive models.
-- Association models are descriptive models that are summaries of data.

-----------------------------------------------------------------------
--                            TEST THE MODEL
-----------------------------------------------------------------------

-- Association rules do not have a predefined test metric.
--
-- Two indirect measures of modeling success are:
--
-- 1. Number of Rules generated: The optimal number of rules is
--    application dependent. In general, an overwhelming number of
--    rules is undesirable for user interpretation. More rules take
--    longer to compute, and also consume storage and CPU cycles.
--    You avoid too many rules by increasing the value for support.
-- 
-- 2. Relevance of rules
--    This can be determined only by user inspection of rules, since
--    it is application dependent. Ideally, we want to find rules with
--    high confidence and with non-obvious patterns. The value for
--    confidence is an indicator of the strength of the rule - so
--    you could set the confidence value high in conjunction with
--    support and see if you get high quality rules.
-- 
-- 3. Frequent itemsets provide an insight into co-occurrence of items.

-----------------------------------------------------------------------
--                            DISPLAY MODEL CONTENT
-----------------------------------------------------------------------

-----------------------------------
-- DISPLAY TOP-10 FREQUENT ITEMSETS
--
break on itemset_id skip 1;
column item format a40
SELECT item, support, number_of_items
  FROM (SELECT I.attribute_subname AS item,
               F.support,
               F.number_of_items
          FROM TABLE(DBMS_DATA_MINING.GET_FREQUENT_ITEMSETS(
                       'AR_SH_sample',
                       10)) F,
               TABLE(F.items) I
        ORDER BY number_of_items, support, item);

-----------------------------------
-- DISPLAY TOP-10 ASSOCIATION RULES
-- ordered by confidence DESC, support DESC
--
SET line 300
column antecedent format a140
column consequent format a140
SELECT ROUND(rule_support,4) support,
--     rule_id,
       ROUND(rule_confidence,4) confidence,
       antecedent,
       consequent
  FROM TABLE(DBMS_DATA_MINING.GET_ASSOCIATION_RULES('AR_SH_sample', 10))
  ORDER BY confidence DESC, support DESC;
