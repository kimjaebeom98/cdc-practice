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

### 2. 간단한 ETL 실행

```bash
# 성공한 ETL DAG만 실행 (빠른 테스트용)
./run-etl.sh
```

### 3. CDC만 테스트 (기존 방식)

```bash
# CDC 파이프라인만 테스트
./test-cdc-safe.sh
```

### 4. 시스템 정리

```bash
# 모든 리소스 완전 정리
./cleanup-all.sh
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
│   ├── kafka_to_postgres_etl.py   # 메인 ETL DAG
│   └── setup_connections.py        # 연결 설정 DAG
├── test-cdc-safe.sh               # CDC 테스트 스크립트
├── test-etl-pipeline.sh           # 전체 ETL 테스트 스크립트
├── cleanup-all.sh                 # 시스템 정리 스크립트
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
- `kafka_to_postgres_etl` DAG가 1분마다 자동 실행됨
- 각 Task의 로그를 통해 상세한 실행 과정 확인 가능

## 🛠️ 트러블슈팅

### ✅ 성공한 ETL 파이프라인

**현재 작동하는 DAG**: `simple_kafka_etl`

- 간단하고 안정적인 Kafka Consumer 설정
- Consumer Group 없이 직접 메시지 처리
- 즉시 커밋으로 트랜잭션 안정성 확보

### 일반적인 문제들

1. **서비스 시작 실패**

   ```bash
   # 로그 확인
   docker-compose logs [서비스명]

   # 서비스 재시작
   docker-compose restart [서비스명]
   ```

2. **커넥터 등록 실패**

   ```bash
   # 커넥터 상태 확인
   curl http://localhost:8083/connectors/mysql-connector/status

   # 커넥터 재등록
   curl -X DELETE http://localhost:8083/connectors/mysql-connector
   curl -X POST -H "Content-Type: application/json" -d @mysql-connector-config-clean.json http://localhost:8083/connectors
   ```

3. **ETL 파이프라인 문제**
   - 📖 **상세한 문제 해결 가이드**: `ETL_TROUBLESHOOTING_GUIDE.md` 참조
   - 성공한 `simple_kafka_etl` DAG 사용 권장
   - Airflow 웹 UI에서 Task 로그 확인: http://localhost:8080 (admin/admin)

## 📈 성능 최적화

- **배치 크기 조정**: Kafka Consumer의 `batch_size` 설정
- **인덱스 최적화**: PostgreSQL 테이블의 인덱스 추가
- **파티셔닝**: 대용량 데이터의 경우 테이블 파티셔닝 고려
- **병렬 처리**: Airflow의 병렬 Task 실행 설정

## 🔒 보안 고려사항

- 프로덕션 환경에서는 강력한 비밀번호 사용
- 네트워크 보안 그룹 설정
- SSL/TLS 암호화 활성화
- 정기적인 보안 업데이트

## 📚 추가 자료

- [Debezium 공식 문서](https://debezium.io/documentation/)
- [Apache Airflow 공식 문서](https://airflow.apache.org/docs/)
- [Kafka 공식 문서](https://kafka.apache.org/documentation/)
- [PostgreSQL 공식 문서](https://www.postgresql.org/docs/)
