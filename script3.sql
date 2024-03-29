CREATE TABLE TEMP2 as
SELECT a.POS_APPLICATION_RK, a.PROPOSAL_DT, a.FLS_AGENCY_CD, 
CASE WHEN LENGTH(a.FLS_CD) BETWEEN 1 AND 7 THEN TO_CHAR(a.FLS_CD,'fm00000000') ELSE a.FLS_CD END FLS_CD, 
sap.PERNR, sap.BEGDA, sap.SUBTY, sap.ENDDA, 
CASE WHEN LENGTH(sap.USRID) BETWEEN 1 AND 7 THEN TO_CHAR(sap.USRID,'fm00000000') ELSE USRID END AGNTNUM,
CASE WHEN TO_DATE(c.PROPOSAL_RECEIVED_DT) >= sap.BEGDA and TO_DATE(c.PROPOSAL_RECEIVED_DT) <= sap.ENDDA THEN 1 ELSE 0 END as VALID,
CASE WHEN TO_DATE(sap.ENDDA) = '31-DEC-99' THEN 1 ELSE 0 END as CURRENT_DT,
'2' as AGNTCOY,
CASE WHEN LENGTH(ag.AGTYPE) > 0 THEN 1 ELSE 0 END as VALID_AGNTNUM
FROM SQL_LINEAGE_TEMP_TABLE a
LEFT JOIN temp_schema_3.POS_APPLICATION c
ON a.POS_APPLICATION_RK = c.POS_APPLICATION_RK
INNER JOIN STAGING_ONE.SRC_SAP_PA0105 sap
ON a.FLS_CD = TO_CHAR(sap.PERNR)
AND sap.SUBTY = '0050'
LEFT JOIN temp_schema_3.AGNTPF ag
ON ag.AGNTNUM = CASE WHEN LENGTH(sap.USRID) BETWEEN 1 AND 7 THEN TO_CHAR(sap.USRID,'fm00000000') ELSE USRID END
AND ag.AGNTCOY = '2'
WHERE NVL(LENGTH(FLS_AGENCY_CD),0)=0 AND NVL(LENGTH(FLS_CD),0) >0;

CREATE TABLE TEMP3 as
SELECT a.*, b.VALID_SUM
FROM TEMP2 a
LEFT JOIN (SELECT POS_APPLICATION_RK, Sum(VALID) as VALID_SUM FROM TEMP2 GROUP BY POS_APPLICATION_RK) b
ON a.POS_APPLICATION_RK = b.POS_APPLICATION_RK;

CREATE TABLE TEMP4 as 
SELECT *
FROM TEMP3 WHERE VALID_AGNTNUM=1 AND ((VALID_SUM=1 and VALID=1) or (VALID_SUM=0 and CURRENT_DT=1)or (VALID_SUM>1 and CURRENT_DT=1));

CREATE TABLE TEMP_FINAL as
SELECT a.*, b.AGNTNUM FROM SQL_LINEAGE_TEMP_TABLE a
LEFT JOIN (SELECT POS_APPLICATION_RK, AGNTNUM, DENSE_RANK() OVER(PARTITION BY POS_APPLICATION_RK ORDER BY BEGDA DESC) RNK FROM TEMP4) b
ON a.POS_APPLICATION_RK = b.POS_APPLICATION_RK
AND b.RNK = 1;

CREATE TABLE TABLE_5 as
SELECT POS_APPLICATION_RK, CASE WHEN LENGTH(AGNTNUM)<>0 THEN AGNTNUM ELSE FLS_AGENCY_CD END as FLS_AGENCY_CD FROM TEMP_FINAL;

DROP TABLE SQL_LINEAGE_TEMP_TABLE;
DROP TABLE TEMP2;
DROP TABLE TEMP3;
DROP TABLE TEMP4;
DROP TABLE TEMP_A;
DROP TABLE TEMP_FINAL;

--Create table for storing policies residing in the provided timeframe
CREATE TABLE TABLE_4 AS
SELECT CH.CHDRNUM
FROM temp_schema_3.HPADPF HP
LEFT JOIN temp_schema_3.CHDRPF CH
ON CH.CHDRNUM = HP.CHDRNUM
AND HP.CHDRCOY = 2
--WHERE TO_DATE(HP.HPROPDTE,'YYYYMMDD') BETWEEN '01-DEC-19' AND '31-DEC-19'
AND SUBSTR(HP.CHDRNUM,1,1) NOT IN ('7','8','9')
AND CH.CNTTYPE <> 'SPG';

--Create table for storing policies and apps
CREATE TABLE TABLE_3 AS
SELECT A.CHDRNUM, COALESCE(APL.POS_APPLICATION_NO,APL1.TTMPRCNO) POS_APPLICATION_NO
FROM TABLE_4 A
LEFT JOIN (SELECT POS_APPLICATION_NO, POLICY_NO, DENSE_RANK() OVER (PARTITION BY POLICY_NO ORDER BY RECORD_CREATED_DT DESC) AS RNK
FROM temp_schema_3.POS_APPLICATION WHERE POLICY_NO IN (SELECT CHDRNUM FROM TABLE_4)) APL
ON A.CHDRNUM = APL.POLICY_NO
AND APL.RNK = 1
LEFT JOIN (SELECT CHDRNUM,TTMPRCNO, DENSE_RANK() OVER (PARTITION BY CHDRNUM ORDER BY DATIME DESC) AS RNK FROM temp_schema_3.TTRCPF WHERE CHDRNUM IN (SELECT CHDRNUM FROM TABLE_4) AND TTMPRCNO IS NOT NULL) APL1
ON A.CHDRNUM = APL1.CHDRNUM
AND APL1.RNK = 1;

--drop initially created table
DROP TABLE TABLE_4;

--create repnum data from available policies and applications
CREATE TABLE TABLE_2 AS
SELECT DISTINCT A.*,
CASE WHEN APP_REP.CREATED >= POL_REP.CREATED THEN POL_REP.LG_CODE ELSE APP_REP.LG_CODE END AS LG_CODE,
CASE WHEN APP_REP.CREATED >= POL_REP.CREATED THEN POL_REP.BRANCH_CODE ELSE APP_REP.BRANCH_CODE END AS BRANCH_CODE, 
CASE WHEN APP_REP.CREATED >= POL_REP.CREATED THEN POL_REP.X_CHANNEL_PARTNER ELSE APP_REP.X_CHANNEL_PARTNER END AS X_CHANNEL_PARTNER
FROM TABLE_3 A
LEFT JOIN (SELECT DISTINCT DENSE_RANK() OVER (PARTITION BY A.OFFER_NUM ORDER BY A.ROW_ID) AS REP_RANK, E.AGNTNUM, A.OFFER_NUM POS_APPLICATION_NO,A.LEAD_NUM, A.CREATED, A.STATUS_CD, A.CREATED_BY, A.X_CHANNEL_PARTNER,
A.X_FULFILLER_ID, A.SRC_ID, A.X_LG_ID, B.X_AGENCY_CODE FULFILLER_AGNTNUM,C.SRC_NUM CAMPAIGN_NUM, D.LOGIN LG_CODE, A.X_BRANCH_CODE AS BRANCH_CODE, E.PAYCLT
FROM SIEBEL.S_LEAD A
LEFT JOIN SIEBEL.S_EMP_PER B ON A.X_FULFILLER_ID=B.ROW_ID
LEFT JOIN SIEBEL.S_SRC C ON A.SRC_ID=C.ROW_ID
LEFT JOIN SIEBEL.S_USER D ON A.X_LG_ID=D.PAR_ROW_ID
LEFT JOIN temp_schema_3.AGLFPF E ON B.X_AGENCY_CODE=E.AGNTNUM
WHERE A.OFFER_NUM IN (SELECT POS_APPLICATION_NO FROM TABLE_3)
AND A.STATUS_CD NOT IN ('System Positive Closure','Invalid') AND D.LOGIN <> 'EAIADMIN') APP_REP
ON A.POS_APPLICATION_NO = APP_REP.POS_APPLICATION_NO
AND APP_REP.REP_RANK = 1
LEFT JOIN (SELECT DISTINCT DENSE_RANK() OVER (PARTITION BY A.OFFER_NUM ORDER BY A.ROW_ID) AS REP_RANK, E.AGNTNUM, A.X_PROPOSAL_NUM CHDRNUM, A.LEAD_NUM, A.CREATED, A.STATUS_CD, A.CREATED_BY, A.X_CHANNEL_PARTNER,
A.X_FULFILLER_ID, A.SRC_ID, A.X_LG_ID, B.X_AGENCY_CODE FULFILLER_AGNTNUM,C.SRC_NUM CAMPAIGN_NUM, D.LOGIN LG_CODE, A.X_BRANCH_CODE AS BRANCH_CODE, E.PAYCLT
FROM SIEBEL.S_LEAD A
LEFT JOIN SIEBEL.S_EMP_PER B ON A.X_FULFILLER_ID=B.ROW_ID
LEFT JOIN SIEBEL.S_SRC C ON A.SRC_ID=C.ROW_ID
LEFT JOIN SIEBEL.S_USER D ON A.X_LG_ID=D.PAR_ROW_ID
LEFT JOIN temp_schema_3.AGLFPF E ON B.X_AGENCY_CODE=E.AGNTNUM
WHERE A.X_PROPOSAL_NUM IN (SELECT CHDRNUM FROM TABLE_3)
AND A.STATUS_CD NOT IN ('System Positive Closure','Invalid') AND D.LOGIN <> 'EAIADMIN') POL_REP
ON A.CHDRNUM = POL_REP.CHDRNUM
AND POL_REP.REP_RANK = 1;

DROP TABLE TABLE_3;

CREATE TABLE TABLE_1 as 
SELECT a.*, 
CASE 
    WHEN b.REPNUM IS NOT NULL THEN b.REPNUM 
    WHEN cm.LG_TO_BE_MAPPED_TO = 'REPNUM' THEN CASE WHEN dtl.LG_CD IS NULL THEN a.LG_CODE ELSE dtl.LG_CD END
    WHEN cm.BRNCH_CD_TO_BE_MAPPED_TO = 'REPNUM' THEN a.BRANCH_CODE 
    WHEN ch.SUB_CHANNEL IN ('BCSS') OR CHANNEL LIKE 'Brokers%' THEN tebt.FLS_AGENCY_CD
    ELSE dtl.LG_CD
END REPNUM, dtl.LG_CD,
ch.CHANNEL, ch.SUB_CHANNEL
FROM TABLE_2 a
LEFT JOIN temp_schema_3.CHDRPF b
ON a.CHDRNUM = b.CHDRNUM
LEFT JOIN temp_schema_3.POS_APPLICATION app
ON a.POS_APPLICATION_NO = app.POS_APPLICATION_NO
LEFT JOIN temp_schema_3.POS_APP_DISTRIBUTOR_DTLS dtl
ON app.POS_APPLICATION_RK = dtl.POS_APPLICATION_RK
LEFT JOIN CHANNEL_MASTERS cm
ON b.AGNTNUM = cm.AGNTNUM
LEFT JOIN TABLE_5 tebt
ON app.POS_APPLICATION_RK = tebt.POS_APPLICATION_RK
LEFT JOIN TEMP_SCHEMA.AGENT_WISE_CHANNEL_SUB_CHNL ch
ON b.AGNTNUM = ch.AGNTNUM;