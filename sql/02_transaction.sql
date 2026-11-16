-- =====================================================================
-- 02_transaction.sql : 주문 생성 + 재고 차감을 하나의 트랜잭션으로 처리
-- 실행 위치 : Supabase SQL Editor
-- 전제 : 노트북(crud_demo.ipynb)을 실행해 회원·상품 데이터가 1건 이상 있어야 함
-- 사용법 : [확인] → [B] → [확인] → [C] → [확인] 순서로 블록을 드래그해 실행한다.
--          (SQL Editor는 마지막 SELECT 결과만 보여주므로 확인 쿼리는 한 줄로 묶음)
-- =====================================================================

-- [확인] 주문 수와 첫 상품 재고
select (select count(*) from public.orders)                      as order_count,
       (select stock from public.products order by id limit 1)  as first_product_stock;


-- [B] 성공 시나리오 : 주문 INSERT와 재고 UPDATE를 모두 반영 → COMMIT
--     기대 결과 : order_count +1, first_product_stock -1
begin;

insert into public.orders (member_id, product_id, quantity, unit_price)
select (select id from public.members order by created_at limit 1),
       p.id, 1, p.price
from public.products p
order by p.id limit 1;

update public.products
set stock = stock - 1
where id = (select id from public.products order by id limit 1);

commit;


-- [C] 실패 시나리오 : 재고보다 많은 수량 주문 → products_stock_ck 위반 오류
--     주문 INSERT는 먼저 실행되지만 같은 트랜잭션이므로 함께 취소(ROLLBACK)된다.
--     기대 결과 : 오류 메시지 후 [확인] 값이 B 실행 직후와 동일 (부분 반영 없음)
begin;

insert into public.orders (member_id, product_id, quantity, unit_price)
select (select id from public.members order by created_at limit 1),
       p.id, 9999, p.price
from public.products p
order by p.id limit 1;

update public.products
set stock = stock - 9999
where id = (select id from public.products order by id limit 1);

commit;


-- [ROLLBACK 직접 사용] 변경 후 확인하고 취소하기
--     기대 결과 : 블록 안 SELECT는 CANCELED, 이후 [확인]에서는 원래 상태 그대로
begin;

update public.orders
set status = 'CANCELED'
where id = (select max(id) from public.orders);

select id, status from public.orders where id = (select max(id) from public.orders);

rollback;
