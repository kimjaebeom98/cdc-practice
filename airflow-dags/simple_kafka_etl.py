#!/usr/bin/env python3
"""
간단하고 안정적인 Kafka to PostgreSQL ETL DAG
"""

import json
import logging
from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook
from kafka import KafkaConsumer
import psycopg2.extras

# DAG 기본 설정
default_args = {
    'owner': 'data-team',
    'depends_on_past': False,
    'start_date': datetime(2025, 9, 18),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
    'catchup': False,  # 과거 데이터 처리 안 함
}

# DAG 정의
dag = DAG(
    'simple_kafka_etl',
    default_args=default_args,
    description='간단한 Kafka to PostgreSQL ETL',
    schedule_interval=None,  # 수동 실행
    catchup=False,
    max_active_runs=1,  # 동시 실행 제한
    tags=['kafka', 'postgresql', 'etl', 'simple']
)

def simple_kafka_consumer():
    """간단한 Kafka Consumer로 메시지를 처리합니다."""
    logging.info("간단한 Kafka ETL 시작")
    
    # PostgreSQL 연결
    postgres_hook = PostgresHook(postgres_conn_id='postgres_dw')
    conn = postgres_hook.get_conn()
    cursor = conn.cursor()
    
    # Kafka Consumer 설정 (고정된 Consumer Group ID 사용)
    consumer = KafkaConsumer(
        'dbserver1.bankdb.bank_accounts',
        bootstrap_servers=['kafka:9092'],
        group_id='airflow-etl-permanent',  # 고정된 Consumer Group ID (중복 생성 방지)
        auto_offset_reset='earliest',  # 처음부터 모든 메시지 읽기
        consumer_timeout_ms=10000,  # 10초 대기
        enable_auto_commit=True,  # 자동 커밋으로 오프셋 관리
        auto_commit_interval_ms=5000,  # 5초마다 오프셋 커밋
        value_deserializer=lambda m: json.loads(m.decode('utf-8')) if m else None
    )
    
    processed_count = 0
    
    try:
        logging.info("Kafka 메시지 읽기 시작...")
        
        # 메시지 처리
        for message in consumer:
            try:
                data = message.value
                if not data:
                    logging.info("빈 메시지 건너뛰기")
                    continue
                
                processed_count += 1
                logging.info(f"메시지 {processed_count}: {data}")
                
                # DELETE 메시지 처리
                if data.get('__deleted') == 'true':
                    original_id = data.get('id')
                    logging.info(f"DELETE 처리: {original_id}")
                    
                    # 중복 처리 방지: 같은 오프셋의 메시지가 이미 처리되었는지 확인
                    cursor.execute("""
                        SELECT COUNT(*) FROM bank_accounts_history 
                        WHERE kafka_offset = %s AND kafka_partition = %s AND kafka_topic = %s
                    """, (message.offset, message.partition, message.topic))
                    
                    duplicate_count = cursor.fetchone()[0]
                    
                    if duplicate_count == 0:
                        # 기존 original_registered_at 조회
                        cursor.execute("""
                            SELECT original_registered_at FROM bank_accounts_current WHERE original_id = %s
                        """, (original_id,))
                        existing_original_registered_at = cursor.fetchone()[0]
                        
                        # 히스토리에 DELETE 기록 추가
                        cursor.execute("""
                            INSERT INTO bank_accounts_history 
                            (original_id, user_id, account, change_type, change_timestamp, 
                             original_registered_at, kafka_offset, kafka_partition, kafka_topic)
                            VALUES (%s, %s, %s, %s, NOW(), %s, %s, %s, %s)
                        """, (
                            original_id, data.get('user_id'), data.get('account'), 
                            'DELETE', existing_original_registered_at,
                            message.offset, message.partition, message.topic
                        ))
                        
                        # current 테이블에서 삭제
                        cursor.execute("DELETE FROM bank_accounts_current WHERE original_id = %s", (original_id,))
                        logging.info(f"DELETE 처리 완료: {original_id}")
                    else:
                        logging.info(f"DELETE 중복 처리 건너뜀: {original_id} (오프셋: {message.offset})")
                
                # INSERT/UPDATE 메시지 처리 
                elif data.get('__deleted') == 'false':
                    original_id = data.get('id')
                    logging.info(f"INSERT/UPDATE 처리: {original_id}")
                    
                    # 중복 처리 방지: 같은 오프셋의 메시지가 이미 처리되었는지 확인
                    cursor.execute("""
                        SELECT COUNT(*) FROM bank_accounts_history 
                        WHERE kafka_offset = %s AND kafka_partition = %s AND kafka_topic = %s
                    """, (message.offset, message.partition, message.topic))
                    
                    duplicate_count = cursor.fetchone()[0]
                    
                    if duplicate_count == 0:
                        # 기존 데이터 확인
                        cursor.execute("SELECT COUNT(*) FROM bank_accounts_current WHERE original_id = %s", (original_id,))
                        existing_count = cursor.fetchone()[0]
                        
                        if existing_count > 0:
                            logging.info(f"✏️ UPDATE: {original_id}")
                            # UPDATE 처리 (original_registered_at은 변경하지 않음)
                            cursor.execute("""
                                UPDATE bank_accounts_current 
                                SET user_id = %s, account = %s, last_updated_at = NOW()
                                WHERE original_id = %s
                            """, (data.get('user_id'), data.get('account'), original_id))
                            
                            # 히스토리에 UPDATE 기록 (기존 original_registered_at 유지)
                            cursor.execute("""
                                SELECT original_registered_at FROM bank_accounts_current WHERE original_id = %s
                            """, (original_id,))
                            existing_original_registered_at = cursor.fetchone()[0]
                            
                            cursor.execute("""
                                INSERT INTO bank_accounts_history 
                                (original_id, user_id, account, change_type, change_timestamp, 
                                 original_registered_at, kafka_offset, kafka_partition, kafka_topic)
                                VALUES (%s, %s, %s, %s, NOW(), %s, %s, %s, %s)
                            """, (
                                original_id, data.get('user_id'), data.get('account'), 
                                'UPDATE', existing_original_registered_at,
                                message.offset, message.partition, message.topic
                            ))
                        else:
                            logging.info(f"INSERT: {original_id}")
                            # INSERT 처리
                            cursor.execute("""
                                INSERT INTO bank_accounts_current 
                                (original_id, user_id, account, original_registered_at, last_updated_at)
                                VALUES (%s, %s, %s, %s, NOW())
                            """, (original_id, data.get('user_id'), data.get('account'), data.get('registered_at')))
                            
                            # 히스토리에 INSERT 기록
                            cursor.execute("""
                                INSERT INTO bank_accounts_history 
                                (original_id, user_id, account, change_type, change_timestamp, 
                                 original_registered_at, kafka_offset, kafka_partition, kafka_topic)
                                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                            """, (
                                original_id, data.get('user_id'), data.get('account'), 
                                'INSERT', data.get('registered_at'), data.get('registered_at'),
                                message.offset, message.partition, message.topic
                            ))
                        
                        logging.info(f"INSERT/UPDATE 처리 완료: {original_id}")
                    else:
                        logging.info(f"INSERT/UPDATE 중복 처리 건너뜀: {original_id} (오프셋: {message.offset})")
                
                # 각 메시지 처리 후 즉시 커밋
                conn.commit()
                logging.info(f"메시지 {processed_count} 처리 완료")
                    
            except Exception as e:
                logging.error(f"❌ 메시지 처리 실패: {e}")
                conn.rollback()
                continue
        
        logging.info(f"총 {processed_count}개 메시지 처리 완료")
        
    except Exception as e:
        logging.error(f"Kafka Consumer 오류: {e}")
        
    finally:
        cursor.close()
        conn.close()
        consumer.close()
        logging.info("리소스 정리 완료")

# Task 정의
simple_consumer_task = PythonOperator(
    task_id='simple_kafka_consumer',
    python_callable=simple_kafka_consumer,
    dag=dag,
)

# Task 순서 정의
simple_consumer_task
