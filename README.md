# CDC + ETL 데이터 파이프라인

MySQL OLTP에서 PostgreSQL OLAP로 실시간 데이터 동기화를 위한 완전한 CDC + ETL 파이프라인입니다.

## 🏗️ 아키텍처

```
MySQL OLTP → Debezium → Kafka → Airflow → PostgreSQL OLAP
```

### 구성 요소

- **MySQL OLTP**: 운영 데이터베이스 (포트: 3307)
- **Debezium**: CDC 커넥터 (포트: 8083)
- **Kafka**: 메시지 큐 (포트: 9092)
- **Airflow**: ETL 오케스트레이션 (포트: 8080)
- **PostgreSQL OLAP**: 데이터 웨어하우스 (포트: 5432)

## 🚀 빠른 시작

### 1. 전체 시스템 시작 및 테스트

```bash
# 전체 ETL 파이프라인 테스트 실행 (권장)
./test-etl-pipeline.sh
```

## 📊 데이터베이스 스키마

### MySQL OLTP (bankdb)

- `bank_accounts`: 사용자 계좌 정보 테이블

### PostgreSQL OLAP (bankdw)

- `bank_accounts_history`: 변경 이력 테이블 (모든 INSERT/UPDATE/DELETE 기록)
- `bank_accounts_current`: 현재 상태 테이블 (최신 상태만 유지)
- `user_account_stats`: 사용자별 통계 테이블

## 🔧 접속 정보

| 서비스           | URL/호스트            | 포트 | 사용자   | 비밀번호   |
| ---------------- | --------------------- | ---- | -------- | ---------- |
| MySQL OLTP       | localhost             | 3307 | debezium | dbz        |
| PostgreSQL OLAP  | localhost             | 5432 | dwuser   | dwpassword |
| Airflow 웹 UI    | http://localhost:8080 | 8080 | admin    | admin      |
| Kafka            | localhost             | 9092 | -        | -          |
| Debezium Connect | http://localhost:8083 | 8083 | -        | -          |

## 📁 프로젝트 구조

```
coinOne-practice/
├── docker-compose.yml              # 전체 서비스 정의
├── mysql-connector-config-clean.json # Debezium 커넥터 설정
├── mysql-init/                     # MySQL 초기화 스크립트
│   └── 01-create-table.sql
├── postgres-dw-init/               # PostgreSQL 초기화 스크립트
│   └── 01-create-dw-schema.sql
├── airflow-dags/                   # Airflow DAG 파일들
│   └── simple_kafka_etl.py        # 메인 ETL DAG
├── test-etl-pipeline.sh           # 전체 ETL 테스트 스크립트
└── requirements.txt                # Python 패키지 의존성
```

## 🔄 ETL 프로세스

1. **CDC (Change Data Capture)**

   - MySQL의 binlog를 통해 실시간 변경사항 감지
   - Debezium이 변경사항을 Kafka로 전송

2. **ETL (Extract, Transform, Load)**

   - Airflow가 Kafka에서 메시지를 읽음
   - 데이터를 변환하여 PostgreSQL에 저장
   - 히스토리 테이블과 현재 상태 테이블 동시 업데이트

3. **데이터 동기화**
   - INSERT: 히스토리 테이블에 기록 + 현재 상태 테이블에 추가
   - UPDATE: 히스토리 테이블에 기록 + 현재 상태 테이블 업데이트
   - DELETE: 히스토리 테이블에 기록 + 현재 상태 테이블에서 삭제

## 🧪 테스트 방법

### 수동 테스트

1. **데이터 변경**

   ```sql
   -- MySQL OLTP에 접속하여 데이터 변경
   docker exec -it mysql-test mysql -u debezium -pdbz
   USE bankdb;

   INSERT INTO bank_accounts (user_id, account) VALUES (1005, 'Test Bank 123-456-789');
   UPDATE bank_accounts SET account = 'Updated Bank 987-654-321' WHERE user_id = 1001;
   DELETE FROM bank_accounts WHERE user_id = 1002;
   ```

2. **결과 확인**

   ```sql
   -- PostgreSQL OLAP에서 결과 확인
   docker exec -it postgres-dw psql -U dwuser -d bankdw

   SELECT * FROM bank_accounts_history ORDER BY change_timestamp DESC LIMIT 10;
   SELECT * FROM bank_accounts_current ORDER BY original_id;
   SELECT * FROM user_account_stats;
   ```

### Airflow 모니터링

- Airflow 웹 UI (http://localhost:8080)에서 DAG 실행 상태 확인

## 📚 추가 자료

- [Debezium 공식 문서](https://debezium.io/documentation/)
- [Apache Airflow 공식 문서](https://airflow.apache.org/docs/)
- [Kafka 공식 문서](https://kafka.apache.org/documentation/)
- [PostgreSQL 공식 문서](https://www.postgresql.org/docs/)
