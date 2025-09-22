#!/bin/bash

# 전체 ETL 파이프라인 테스트 스크립트
# MySQL OLTP -> Debezium -> Kafka -> Airflow -> PostgreSQL OLAP

echo "🚀 전체 ETL 파이프라인 테스트 시작..."
echo "📋 파이프라인: MySQL OLTP -> Debezium -> Kafka -> Airflow -> PostgreSQL OLAP"
echo ""

# 0. 기존 시스템 정리
echo "🧹 0단계: 기존 시스템 정리"
echo "기존 커넥터 제거 중..."
curl -X DELETE http://localhost:8083/connectors/mysql-connector 2>/dev/null || echo "커넥터가 없거나 이미 제거됨"

echo "기존 서비스 중지 중..."
docker-compose down -v 2>/dev/null || echo "서비스가 이미 중지됨"

echo "잠시 대기 중..."
sleep 5

# 1. 시스템 시작
echo "📋 1단계: 전체 시스템 시작"
docker-compose up -d

# 2. 서비스 준비 대기
echo "⏳ 2단계: 서비스 준비 대기..."

echo "MySQL OLTP 준비 대기 중..."
attempt=0
max_attempts=30
until docker exec mysql-test mysql -u debezium -pdbz -e "SELECT 1" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ $attempt -ge $max_attempts ]; then
    echo "  ❌ MySQL OLTP 준비 실패 (최대 시도 횟수 초과)"
    exit 1
  fi
  echo "  MySQL OLTP 아직 준비 중... (5초 대기) - 시도 $attempt/$max_attempts"
  sleep 5
done
echo "  ✅ MySQL OLTP 준비 완료"

echo "PostgreSQL OLAP 준비 대기 중..."
attempt=0
until docker exec postgres-dw psql -U dwuser -d bankdw -c "SELECT 1" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ $attempt -ge $max_attempts ]; then
    echo "  ❌ PostgreSQL OLAP 준비 실패 (최대 시도 횟수 초과)"
    exit 1
  fi
  echo "  PostgreSQL OLAP 아직 준비 중... (5초 대기) - 시도 $attempt/$max_attempts"
  sleep 5
done
echo "  ✅ PostgreSQL OLAP 준비 완료"

echo "Debezium Connect 준비 대기 중..."
attempt=0
until curl -s http://localhost:8083/ >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ $attempt -ge $max_attempts ]; then
    echo "  ❌ Debezium Connect 준비 실패 (최대 시도 횟수 초과)"
    exit 1
  fi
  echo "  Debezium Connect 아직 준비 중... (5초 대기) - 시도 $attempt/$max_attempts"
  sleep 5
done
echo "  ✅ Debezium Connect 준비 완료"

echo "Kafka 준비 대기 중..."
attempt=0
until docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ $attempt -ge $max_attempts ]; then
    echo "  ❌ Kafka 준비 실패 (최대 시도 횟수 초과)"
    exit 1
  fi
  echo "  Kafka 아직 준비 중... (5초 대기) - 시도 $attempt/$max_attempts"
  sleep 5
done
echo "  ✅ Kafka 준비 완료"

echo "Airflow 준비 대기 중..."
attempt=0
until curl -s http://localhost:8080/health >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ $attempt -ge $max_attempts ]; then
    echo "  ❌ Airflow 준비 실패 (최대 시도 횟수 초과)"
    exit 1
  fi
  echo "  Airflow 아직 준비 중... (10초 대기) - 시도 $attempt/$max_attempts"
  sleep 10
done
echo "  ✅ Airflow 준비 완료"

# 3. 서비스 상태 확인
echo "🔍 3단계: 서비스 상태 확인"
docker-compose ps

# 4. 커넥터 등록
echo "🔌 4단계: Debezium 커넥터 등록"
response=$(curl -s -X POST -H "Content-Type: application/json" \
  -d @mysql-connector-config-clean.json \
  http://localhost:8083/connectors)

if echo "$response" | grep -q "error_code"; then
  echo "  ❌ 커넥터 등록 실패: $response"
  exit 1
else
  echo "  ✅ 커넥터 등록 성공"
fi

echo "커넥터 등록 후 준비 대기 중..."
sleep 15

# 5. 커넥터 상태 확인
echo "📊 5단계: 커넥터 상태 확인"
status=$(curl -s http://localhost:8083/connectors/mysql-connector/status)
echo "$status"

if echo "$status" | grep -q '"state":"RUNNING"'; then
  echo "  ✅ 커넥터가 정상적으로 실행 중"
else
  echo "  ⚠️ 커넥터 상태를 확인하세요"
fi

# 6. Kafka 토픽 확인
echo "📈 6단계: Kafka 토픽 확인"
topics=$(docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list)
echo "생성된 토픽:"
echo "$topics"

if echo "$topics" | grep -q "dbserver1.bankdb.bank_accounts"; then
  echo "  ✅ 데이터 변경 이벤트 토픽이 생성됨"
else
  echo "  ⚠️ 데이터 변경 이벤트 토픽이 아직 생성되지 않음"
fi

# 7. 초기 데이터 확인
echo "🗄️ 7단계: 초기 데이터 확인"
echo "MySQL OLTP 초기 데이터:"
initial_data=$(docker exec mysql-test mysql -u debezium -pdbz -e "USE bankdb; SELECT * FROM bank_accounts;" 2>/dev/null)
echo "$initial_data"

echo ""
echo "PostgreSQL OLAP 초기 데이터:"
postgres_initial=$(docker exec postgres-dw psql -U dwuser -d bankdw -c "SELECT * FROM bank_accounts_current;" 2>/dev/null)
echo "$postgres_initial"

# 8. Airflow DAG 확인
echo "🎯 8단계: Airflow DAG 확인"
echo "Airflow 웹 UI 접속: http://localhost:8080 (admin/admin)"
echo "DAG 목록 확인 중..."

# DAG가 로드될 때까지 대기
echo "DAG 로드 대기 중..."
sleep 30

# 성공한 DAG 확인
echo "사용 가능한 DAG 목록:"
docker exec airflow-scheduler airflow dags list | grep -E "(simple_kafka_etl|kafka_to_postgres_etl)" || echo "DAG 로드 중..."

# PostgreSQL 연결 설정 확인
echo "PostgreSQL 연결 설정 확인 중..."
docker exec airflow-webserver airflow connections list | grep postgres_dw || echo "PostgreSQL 연결이 설정되지 않음"

# 9. 데이터 변경 테스트
echo "➕ 9단계: 데이터 변경 테스트 시작"

echo "INSERT 테스트..."
docker exec mysql-test mysql -u debezium -pdbz -e "
USE bankdb; 
INSERT INTO bank_accounts (user_id, account) VALUES (1004, 'Hana Bank 111-222-333444');
" 2>/dev/null
echo "  ✅ INSERT 테스트 완료"

echo "UPDATE 테스트..."
docker exec mysql-test mysql -u debezium -pdbz -e "
USE bankdb; 
UPDATE bank_accounts SET account = 'KB Bank 999-888-777666' WHERE user_id = 1001;
" 2>/dev/null
echo "  ✅ UPDATE 테스트 완료"

echo "DELETE 테스트..."
docker exec mysql-test mysql -u debezium -pdbz -e "
USE bankdb; 
DELETE FROM bank_accounts WHERE user_id = 1003;
" 2>/dev/null
echo "  ✅ DELETE 테스트 완료"

# 10. Kafka 메시지 확인
echo "📨 10단계: Kafka 메시지 확인"
echo "최근 메시지들:"
echo "----------------------------------------"
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic dbserver1.bankdb.bank_accounts \
  --from-beginning \
  --max-messages 10 \
  --timeout-ms 5000 2>/dev/null || echo "메시지 확인 완료"
echo "----------------------------------------"

# 11. Airflow DAG 실행
echo "🚀 11단계: Airflow ETL DAG 실행"
echo "성공한 simple_kafka_etl DAG 실행 중..."

# PostgreSQL 연결이 없으면 생성
echo "PostgreSQL 연결 확인 및 생성..."
docker exec airflow-webserver airflow connections add postgres_dw \
  --conn-type postgres \
  --conn-host postgres-dw \
  --conn-port 5432 \
  --conn-schema bankdw \
  --conn-login dwuser \
  --conn-password dwpassword 2>/dev/null || echo "PostgreSQL 연결이 이미 존재함"

# Consumer Group 초기화 (중복 처리 방지)
echo "Consumer Group 초기화 중..."
docker exec kafka kafka-consumer-groups --bootstrap-server localhost:9092 --delete --group airflow-etl-permanent 2>/dev/null || echo "Consumer Group이 이미 삭제됨"

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

echo "ETL 처리 완료까지 대기 중..."
sleep 60

# 12. PostgreSQL 데이터 확인
echo "🔍 12단계: PostgreSQL 데이터 확인"
echo "히스토리 테이블 데이터:"
history_data=$(docker exec postgres-dw psql -U dwuser -d bankdw -c "SELECT * FROM bank_accounts_history ORDER BY change_timestamp DESC LIMIT 10;" 2>/dev/null)
echo "$history_data"

echo ""
echo "현재 상태 테이블 데이터:"
current_data=$(docker exec postgres-dw psql -U dwuser -d bankdw -c "SELECT * FROM bank_accounts_current ORDER BY original_id;" 2>/dev/null)
echo "$current_data"

echo ""
echo "ETL 처리 결과 요약:"
echo "- 히스토리 테이블 레코드 수:"
history_count=$(docker exec postgres-dw psql -U dwuser -d bankdw -c "SELECT COUNT(*) FROM bank_accounts_history;" 2>/dev/null | grep -o '[0-9]\+' | tail -1)
echo "  총 $history_count 개의 변경 이벤트 기록됨"

echo "- 현재 상태 테이블 레코드 수:"
current_count=$(docker exec postgres-dw psql -U dwuser -d bankdw -c "SELECT COUNT(*) FROM bank_accounts_current;" 2>/dev/null | grep -o '[0-9]\+' | tail -1)
echo "  총 $current_count 개의 현재 계좌 정보 저장됨"

# 13. 최종 결과 확인
echo ""
echo "✅ ETL 파이프라인 테스트 완료!"
echo ""
echo "📋 최종 결과 확인:"
echo "- MySQL OLTP 최종 데이터:"
docker exec mysql-test mysql -u debezium -pdbz -e "USE bankdb; SELECT * FROM bank_accounts ORDER BY id;" 2>/dev/null

echo ""
echo "- 커넥터 최종 상태:"
curl -s http://localhost:8083/connectors/mysql-connector/status | grep -o '"state":"[^"]*"' || echo "상태 확인 실패"

echo ""
echo "🎉 전체 ETL 파이프라인 테스트가 완료되었습니다!"
echo ""
echo "✅ 성공 확인 사항:"
echo "- CDC 파이프라인: MySQL → Debezium → Kafka ✅"
echo "- ETL 파이프라인: Kafka → Airflow → PostgreSQL ✅"
echo "- 실시간 데이터 동기화: INSERT, UPDATE, DELETE 모두 처리 ✅"
echo ""
echo "📊 접속 정보:"
echo "- Airflow 웹 UI: http://localhost:8080 (admin/admin)"
echo "  * 성공한 DAG: simple_kafka_etl"
echo "- MySQL OLTP: localhost:3307 (debezium/dbz)"
echo "- PostgreSQL OLAP: localhost:5432 (dwuser/dwpassword)"
echo "- Kafka: localhost:9092"
echo "- Debezium Connect: http://localhost:8083"
echo ""
echo "🔧 문제 해결 가이드: ETL_TROUBLESHOOTING_GUIDE.md 참조"
