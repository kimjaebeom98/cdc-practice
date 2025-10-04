# ETL 파이프라인 문제 해결 가이드

## 📋 문제 해결 과정 요약

### 초기 상황

- ✅ CDC 파이프라인 (MySQL → Debezium → Kafka)은 정상 작동
- ❌ ETL 파이프라인 (Kafka → PostgreSQL)이 작동하지 않음
- ❌ Consumer가 메시지를 읽지 못하거나 DELETE 메시지만 반복 처리

---

## 🔍 문제 진단 과정

### 1단계: Kafka 메시지 존재 확인

```bash
# Kafka 토픽의 메시지 개수 확인
docker exec kafka kafka-run-class kafka.tools.GetOffsetShell --bootstrap-server localhost:9092 --topic dbserver1.bankdb.bank_accounts
```

**결과**: `dbserver1.bankdb.bank_accounts:0:14` - 14개 메시지 존재 확인

### 2단계: 간단한 Consumer 테스트

```python
# test_kafka_consumer.py 생성 및 테스트
consumer = KafkaConsumer(
    'dbserver1.bankdb.bank_accounts',
    bootstrap_servers=['kafka:9092'],  # 중요: localhost가 아닌 kafka:9092
    group_id='test-consumer-group',
    auto_offset_reset='earliest',
    consumer_timeout_ms=10000,
    value_deserializer=lambda m: json.loads(m.decode('utf-8')) if m else None
)
```

**결과**: ✅ Consumer는 정상 작동, INSERT 메시지들을 성공적으로 읽음

### 3단계: Airflow DAG 문제 진단

```bash
# Airflow DAG 실행 로그 확인
docker exec airflow-scheduler airflow tasks test kafka_to_postgres_etl consume_kafka_messages 2025-09-18
```

**발견된 문제들**:

1. **파티션 할당 문제**: `Updated partition assignment: []` - Consumer가 파티션에 할당되지 않음
2. **Consumer Group 오프셋 문제**: Consumer가 메시지를 읽었지만 처리 중 오류 발생
3. **DELETE 메시지 반복 처리**: 같은 오프셋의 DELETE 메시지만 계속 처리

**실제 오류 로그**:

```
[2025-09-18T11:32:00.459+0000] {subscription_state.py:257} INFO - Updated partition assignment: []
[2025-09-18T11:32:19.729+0000] {kafka_to_postgres_etl.py:130} INFO - 🎉 총 0개 메시지 처리 완료
```

**Consumer Group 상태 확인**:

```bash
docker exec kafka kafka-consumer-groups --bootstrap-server localhost:9092 --group airflow-etl-simple --describe
```

**결과**: `CURRENT-OFFSET=13, LOG-END-OFFSET=14, LAG=1` - 메시지를 읽었지만 처리하지 못함

---

## 🛠️ 해결 방법

### 문제 1: 파티션 할당 실패

**원인**: Consumer Group 설정 문제로 인한 파티션 할당 실패

**해결책**:

```python
# 기존 문제가 있던 설정
consumer = KafkaConsumer(
    'dbserver1.bankdb.bank_accounts',
    bootstrap_servers=['kafka:9092'],
    group_id='airflow-etl-simple',  # Consumer Group 사용
    auto_offset_reset='earliest',
    consumer_timeout_ms=20000,
    enable_auto_commit=False,
    value_deserializer=lambda m: json.loads(m.decode('utf-8')) if m else None
)

# 해결된 설정
consumer = KafkaConsumer(
    'dbserver1.bankdb.bank_accounts',
    bootstrap_servers=['kafka:9092'],
    group_id=None,  # Consumer Group 사용 안 함
    auto_offset_reset='earliest',
    consumer_timeout_ms=15000,
    value_deserializer=lambda m: json.loads(m.decode('utf-8')) if m else None
)
```

### 문제 2: 메시지 반복 처리

**원인**: Consumer Group 오프셋 관리 문제로 인한 같은 메시지 반복 처리

**기존 DAG의 구체적 문제점**:

```python
# kafka_to_postgres_etl.py의 문제가 있던 부분
consumer = KafkaConsumer(
    'dbserver1.bankdb.bank_accounts',
    bootstrap_servers=['kafka:9092'],
    group_id=f'airflow-etl-{int(time.time())}',  # 동적 그룹 ID
    auto_offset_reset='earliest',
    consumer_timeout_ms=30000,
    enable_auto_commit=True,
    auto_commit_interval_ms=5000,
    session_timeout_ms=30000,
    heartbeat_interval_ms=10000,
    value_deserializer=lambda m: json.loads(m.decode('utf-8')) if m else None
)
```

**문제점**:

1. **동적 Consumer Group ID**: 매번 새로운 그룹이 생성되어 오프셋 관리 혼란
2. **복잡한 설정**: 과도한 타임아웃과 커밋 설정으로 인한 불안정성
3. **메시지 처리 로직 복잡성**: 기존 데이터 확인 로직이 복잡하여 오류 발생

**해결책**: 완전히 새로운 DAG 작성 (`simple_kafka_etl.py`)

### 문제 3: 복잡한 Consumer 설정

**원인**: 과도하게 복잡한 Consumer 설정으로 인한 불안정성

**기존 DAG의 메시지 처리 로직 문제**:

```python
# kafka_to_postgres_etl.py의 복잡한 처리 로직
def process_insert_message(cursor, data, message):
    # 복잡한 데이터 추출 로직
    original_id = data.get('id')
    user_id = data.get('user_id')
    account = data.get('account')
    registered_at = data.get('registered_at')

    # 중복 확인 로직
    cursor.execute("SELECT COUNT(*) FROM bank_accounts_current WHERE original_id = %s", (original_id,))
    existing_count = cursor.fetchone()[0]

    if existing_count == 0:
        # INSERT 로직
        cursor.execute("""
            INSERT INTO bank_accounts_current
            (original_id, user_id, account, original_registered_at, last_updated_at)
            VALUES (%s, %s, %s, %s, NOW())
        """, (original_id, user_id, account, registered_at))

        # 히스토리 기록
        cursor.execute("""
            INSERT INTO bank_accounts_history
            (original_id, user_id, account, change_type, change_timestamp,
             original_registered_at, kafka_offset, kafka_partition, kafka_topic)
            VALUES (%s, %s, %s, %s, NOW(), %s, %s, %s, %s)
        """, (original_id, user_id, account, 'INSERT', registered_at,
              message.offset, message.partition, message.topic))
```

**문제점**:

1. **함수 분리로 인한 복잡성**: `process_insert_message`, `process_update_message`, `process_delete_message` 함수들이 각각 복잡
2. **오류 처리 부족**: 각 함수에서 예외 처리가 부족하여 하나의 오류가 전체를 중단시킴
3. **트랜잭션 관리**: 각 메시지별로 개별 커밋이 아닌 배치 커밋으로 인한 불안정성

**새로운 DAG의 간단한 해결책**:

```python
# simple_kafka_etl.py의 간단한 처리 로직
for message in consumer:
    try:
        data = message.value
        if not data:
            continue

        processed_count += 1
        logging.info(f"📨 메시지 {processed_count}: {data}")

        # DELETE 메시지 처리
        if data.get('__deleted') == 'true':
            # 간단한 DELETE 로직
            cursor.execute("DELETE FROM bank_accounts_current WHERE original_id = %s", (data.get('id'),))
            # 히스토리 기록
            cursor.execute("INSERT INTO bank_accounts_history ...")

        # INSERT/UPDATE 메시지 처리
        elif data.get('__deleted') == 'false':
            # 기존 데이터 확인
            cursor.execute("SELECT COUNT(*) FROM bank_accounts_current WHERE original_id = %s", (data.get('id'),))
            existing_count = cursor.fetchone()[0]

            if existing_count > 0:
                # UPDATE 로직
                cursor.execute("UPDATE bank_accounts_current SET ...")
            else:
                # INSERT 로직
                cursor.execute("INSERT INTO bank_accounts_current ...")

        # 각 메시지 처리 후 즉시 커밋
        conn.commit()
        logging.info(f"✅ 메시지 {processed_count} 처리 완료")

    except Exception as e:
        logging.error(f"❌ 메시지 처리 실패: {e}")
        conn.rollback()
        continue
```

**핵심 개선사항**:

1. **단일 루프**: 모든 처리를 하나의 루프에서 처리하여 복잡성 제거
2. **즉시 커밋**: 각 메시지 처리 후 즉시 커밋하여 트랜잭션 안정성 확보
3. **간단한 예외 처리**: try-catch로 각 메시지별 독립적 처리
4. **명확한 로깅**: 각 단계별 상세한 로그로 디버깅 용이

---

## 📊 성공 결과

### 최종 성공 로그

```
[2025-09-18T11:35:38.731+0000] {simple_kafka_etl.py:38} INFO - 🚀 간단한 Kafka ETL 시작
[2025-09-18T11:35:38.851+0000] {subscription_state.py:257} INFO - Updated partition assignment: [('dbserver1.bankdb.bank_accounts', 0)]
[2025-09-18T11:35:38.959+0000] {simple_kafka_etl.py:67} INFO - 📨 메시지 1: {'id': 1, 'user_id': 1001, 'account': 'KB Bank 123-456-789012', 'registered_at': '2025-09-18T01:52:22Z', '__deleted': 'false'}
[2025-09-18T11:35:38.960+0000] {simple_kafka_etl.py:89} INFO - ➕ INSERT/UPDATE 처리: 1
[2025-09-18T11:35:38.961+0000] {simple_kafka_etl.py:116} INFO - ➕ INSERT: 1
[2025-09-18T11:35:38.964+0000] {simple_kafka_etl.py:138} INFO - ✅ 메시지 1 처리 완료
...
[2025-09-18T11:35:38.978+0000] {simple_kafka_etl.py:150} INFO - 🎉 총 10개 메시지 처리 완료
```

### PostgreSQL 결과

**현재 상태 테이블**: 7개 계좌 정보 저장
**히스토리 테이블**: 모든 변경사항 (INSERT, UPDATE, DELETE) 기록

---

## 🔧 핵심 해결 포인트

### 1. Consumer Group 제거

- `group_id=None`으로 설정하여 파티션 할당 문제 해결
- 오프셋 관리 복잡성 제거

### 2. 간단한 설정 사용

- 최소한의 Consumer 설정으로 안정성 확보
- 불필요한 고급 기능 제거

### 3. 즉시 커밋

- 각 메시지 처리 후 즉시 PostgreSQL 커밋
- 트랜잭션 안정성 확보

### 4. 명확한 로깅

- 각 단계별 상세한 로그 출력
- 문제 발생 시 빠른 진단 가능

### 5. 코드 구조 단순화

**기존 DAG (kafka_to_postgres_etl.py)**:

- 복잡한 함수 분리 (`process_insert_message`, `process_update_message`, `process_delete_message`)
- 배치 커밋으로 인한 불안정성
- 동적 Consumer Group ID로 인한 오프셋 혼란

**새로운 DAG (simple_kafka_etl.py)**:

- 단일 루프에서 모든 처리
- 각 메시지별 즉시 커밋
- Consumer Group 없이 직접 메시지 처리
- 간단한 예외 처리로 안정성 확보

---

## 📝 교훈

1. **단순함이 최고**: 복잡한 설정보다는 간단하고 안정적인 설정이 더 좋음
2. **Consumer Group 신중 사용**: 필요하지 않다면 Consumer Group 사용을 피할 것
3. **단계별 테스트**: 전체 파이프라인보다는 각 구성요소를 개별적으로 테스트
4. **상세한 로깅**: 문제 발생 시 빠른 진단을 위한 로깅 필수

---

## 🔄 최신 트러블슈팅 (Airflow 자동 실행 문제)

### 문제 상황

**사용자 질문**: "엥 갑자기 왜 되는거야? dag를 수동으로 실행시켜서 그런거야? 그러면 @test-etl-pipeline.sh 에서 자동으로 dag를 실행시키면 안되는거 아니야?"

**발견된 문제**:

- ✅ DAG 수동 실행 시에는 정상 작동
- ❌ `test-etl-pipeline.sh` 스크립트에서 자동 실행 시 실패
- ❌ DAG가 `queued` 상태로 멈춰있음

### 문제 진단 과정

#### 1단계: DAG 상태 확인

```bash
# DAG 실행 상태 확인
docker exec airflow-webserver airflow dags list-runs -d simple_kafka_etl
```

**결과**:

```
conf | dag_id           | dag_run_id           | state
=====+==================+======================+=======
{}   | simple_kafka_etl | manual__2025-09-18T1 | queued
     |                  | 2:45:25+00:00        |
```

**문제 발견**: DAG가 `queued` 상태로 멈춰있어서 실행되지 않음

#### 2단계: Airflow Scheduler 상태 확인

```bash
# Airflow Scheduler 로그 확인
docker logs airflow-scheduler --tail 20
```

**결과**: Scheduler는 정상 실행 중이지만 DAG를 실행하지 못함

#### 3단계: Airflow 설정 확인

**발견된 핵심 문제**:

```yaml
# docker-compose.yml의 문제가 있던 설정
environment:
  AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION: "true" # ❌ 문제!
```

**문제점**: DAG가 생성될 때 자동으로 일시정지(paused) 상태로 설정됨

### 해결 방법

#### 1단계: Airflow 설정 수정

```yaml
# docker-compose.yml 수정
environment:
  AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION: "false" # ✅ 해결!
```

**수정 위치**: `airflow-webserver`와 `airflow-scheduler` 서비스 모두

#### 2단계: DAG 설정 개선

```python
# simple_kafka_etl.py 개선
default_args = {
    'owner': 'data-team',
    'depends_on_past': False,
    'start_date': datetime(2025, 9, 18),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
    'catchup': False,  # ✅ 과거 데이터 처리 안 함
}

dag = DAG(
    'simple_kafka_etl',
    default_args=default_args,
    description='간단한 Kafka to PostgreSQL ETL',
    schedule_interval=None,  # 수동 실행
    catchup=False,
    max_active_runs=1,  # ✅ 동시 실행 제한
    tags=['kafka', 'postgresql', 'etl', 'simple']
)
```

#### 3단계: 스크립트 개선

```bash
# test-etl-pipeline.sh 개선
# 성공한 DAG 실행 (안정적인 방식)
echo "simple_kafka_etl DAG 실행 중..."

# DAG 활성화 확인
echo "DAG 활성화 확인..."
docker exec airflow-webserver airflow dags unpause simple_kafka_etl

# 잠시 대기
sleep 5

# DAG 트리거
echo "DAG 트리거 중..."
docker exec airflow-scheduler airflow dags trigger simple_kafka_etl

# 잠시 대기 후 상태 확인
echo "DAG 실행 상태 확인..."
sleep 15

# DAG 실행 상태 확인
echo "DAG 실행 목록:"
docker exec airflow-webserver airflow dags list-runs -d simple_kafka_etl --limit 3
```

### 성공 결과

#### 최종 성공 로그

```bash
🚀 11단계: Airflow ETL DAG 실행
성공한 simple_kafka_etl DAG 실행 중...
PostgreSQL 연결 확인 및 생성...
Successfully added `conn_id`=postgres_dw : postgres://dwuser:******@postgres-dw:5432/bankdw
simple_kafka_etl DAG 실행 중...
DAG 활성화 확인...
Dag: simple_kafka_etl, paused: False  # ✅ 활성화됨
DAG 트리거 중...
DAG 실행 상태 확인...
```

#### PostgreSQL 결과

**현재 상태 테이블**: 3개 레코드

```
 id | original_id | user_id |           account           | original_registered_at |      last_updated_at
----+-------------+---------+-----------------------------+------------------------+----------------------------
  1 |           1 |    1001 | KB Bank 999-888-777666      | 2025-09-18 12:43:29    | 2025-09-18 12:45:30.167309
  2 |           2 |    1002 | Shinhan Bank 987-654-321098 | 2025-09-18 03:43:29    | 2025-09-18 12:45:30.163069
  4 |           4 |    1004 | Hana Bank 111-222-333444    | 2025-09-18 12:45:01    | 2025-09-18 12:45:30.166177
```

**히스토리 테이블**: 7개 레코드 (모든 변경 이벤트 기록)

### 핵심 해결 포인트

#### 1. Airflow 설정 수정

- `AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION: "false"`로 변경
- DAG가 생성될 때 자동으로 활성화되도록 설정

#### 2. DAG 설정 개선

- `catchup=False`: 과거 데이터 처리 방지
- `max_active_runs=1`: 동시 실행 제한으로 안정성 확보

#### 3. 스크립트 개선

- DAG 활성화 확인 단계 추가
- 상태 체크 로직 강화
- 자동 실행을 위한 안정적인 프로세스 구축

### 교훈

1. **Airflow 설정의 중요성**: 기본 설정이 DAG 실행에 큰 영향을 미침
2. **단계별 확인**: DAG 활성화 상태를 명시적으로 확인하는 것이 중요
3. **설정 문서화**: 각 설정의 의미와 영향을 명확히 이해할 필요
4. **자동화 검증**: 스크립트의 자동 실행이 실제로 작동하는지 반드시 검증

---

## 🚀 최종 아키텍처

```
MySQL OLTP DB → Debezium → Kafka → Airflow ETL → PostgreSQL OLAP DB
     ✅              ✅        ✅         ✅              ✅
```

**실시간 데이터 변경사항이 성공적으로 데이터 웨어하우스에 저장됨**

### 최종 성공 확인

✅ **CDC 파이프라인**: MySQL → Debezium → Kafka 완벽하게 작동
✅ **ETL 파이프라인**: Kafka → Airflow → PostgreSQL 완벽하게 작동  
✅ **실시간 데이터 동기화**: INSERT, UPDATE, DELETE 모두 처리
✅ **Airflow 자동 실행**: 설정 수정으로 DAG가 자동으로 실행됨
✅ **스크립트 자동화**: `./test-etl-pipeline.sh` 실행 시 전체 파이프라인 자동 실행
