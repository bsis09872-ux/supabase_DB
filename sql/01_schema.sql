-- =====================================================================
-- 01_schema.sql : 회원(members) · 상품(products) · 주문(orders) 테이블 생성
-- 실행 위치 : Supabase SQL Editor (새 개인 프로젝트에서 한 번 전체 실행)
-- 명명 규칙 : 테이블은 복수형 snake_case, PK는 id, FK는 <참조테이블 단수>_id,
--             제약조건은 <테이블>_<컬럼>_<pk|fk|ck|uq>
-- =====================================================================

-- 재실행할 수 있도록 의존 순서의 역순으로 정리 (DROP)
drop table if exists public.orders;
drop table if exists public.products;
drop table if exists public.members;

-- ---------------------------------------------------------------------
-- 1. 회원 : Supabase Auth 계정(auth.users) 1명당 회원 정보 1행 (1:1)
-- ---------------------------------------------------------------------
create table public.members (
    id          uuid        not null,
    email       text        not null,
    name        text        not null,
    role        text        not null default 'BUYER',
    phone       text,
    address     text,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    constraint members_id_pk    primary key (id),
    constraint members_id_fk    foreign key (id) references auth.users (id) on delete cascade,
    constraint members_email_uq unique (email),
    constraint members_role_ck  check (role in ('BUYER', 'SELLER'))
);

-- ---------------------------------------------------------------------
-- 2. 상품 : 판매자(members) 1명이 여러 상품을 등록 (1:N)
-- ---------------------------------------------------------------------
create table public.products (
    id          bigint      generated always as identity,
    seller_id   uuid        not null,
    name        text        not null,
    price       integer     not null,
    stock       integer     not null default 0,
    description text,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    constraint products_id_pk        primary key (id),
    constraint products_seller_id_fk foreign key (seller_id) references public.members (id) on delete cascade,
    constraint products_price_ck     check (price >= 0),
    constraint products_stock_ck     check (stock >= 0)
);

-- ---------------------------------------------------------------------
-- 3. 주문 : 회원 1명이 여러 주문, 상품 1개가 여러 주문에 포함 (1:N, 1:N)
--    주문 이력 보존을 위해 주문이 있는 회원·상품은 삭제 불가 (RESTRICT)
-- ---------------------------------------------------------------------
create table public.orders (
    id          bigint      generated always as identity,
    member_id   uuid        not null,
    product_id  bigint      not null,
    quantity    integer     not null,
    unit_price  integer     not null,
    total_price integer     generated always as (quantity * unit_price) stored,
    status      text        not null default 'PENDING',
    ordered_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    constraint orders_id_pk         primary key (id),
    constraint orders_member_id_fk  foreign key (member_id)  references public.members (id)  on delete restrict,
    constraint orders_product_id_fk foreign key (product_id) references public.products (id) on delete restrict,
    constraint orders_quantity_ck   check (quantity > 0),
    constraint orders_unit_price_ck check (unit_price >= 0),
    constraint orders_status_ck     check (status in ('PENDING', 'PAID', 'SHIPPED', 'DELIVERED', 'CANCELED'))
);

create index products_seller_id_idx on public.products (seller_id);
create index orders_member_id_idx   on public.orders (member_id);
create index orders_product_id_idx  on public.orders (product_id);

-- 변경(ALTER) 예시 : 상품 설명 길이 제한 추가
alter table public.products
    add constraint products_description_ck check (char_length(description) <= 500);

-- ---------------------------------------------------------------------
-- 4. updated_at 자동 갱신 트리거
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

create trigger members_set_updated_at  before update on public.members  for each row execute function public.set_updated_at();
create trigger products_set_updated_at before update on public.products for each row execute function public.set_updated_at();
create trigger orders_set_updated_at   before update on public.orders   for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- 5. 권한 + RLS(Row Level Security) : 로그인한 사용자는 자기 데이터만 다룸
-- ---------------------------------------------------------------------
grant select, insert, update, delete on public.members, public.products, public.orders to authenticated;
grant select on public.products to anon;

alter table public.members  enable row level security;
alter table public.products enable row level security;
alter table public.orders   enable row level security;

-- 회원 : 본인 행만 조회·생성·수정·삭제
create policy members_select_own on public.members for select to authenticated using (id = (select auth.uid()));
create policy members_insert_own on public.members for insert to authenticated with check (id = (select auth.uid()));
create policy members_update_own on public.members for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy members_delete_own on public.members for delete to authenticated using (id = (select auth.uid()));

-- 상품 : 누구나 조회, SELLER 회원만 본인 명의로 등록, 본인 상품만 수정·삭제
create policy products_select_all on public.products for select to anon, authenticated using (true);
create policy products_insert_seller on public.products for insert to authenticated
    with check (
        seller_id = (select auth.uid())
        and exists (select 1 from public.members m where m.id = (select auth.uid()) and m.role = 'SELLER')
    );
create policy products_update_own on public.products for update to authenticated using (seller_id = (select auth.uid())) with check (seller_id = (select auth.uid()));
create policy products_delete_own on public.products for delete to authenticated using (seller_id = (select auth.uid()));

-- 주문 : 본인 주문만 조회·생성·수정·삭제
create policy orders_select_own on public.orders for select to authenticated using (member_id = (select auth.uid()));
create policy orders_insert_own on public.orders for insert to authenticated with check (member_id = (select auth.uid()));
create policy orders_update_own on public.orders for update to authenticated using (member_id = (select auth.uid())) with check (member_id = (select auth.uid()));
create policy orders_delete_own on public.orders for delete to authenticated using (member_id = (select auth.uid()));

-- ---------------------------------------------------------------------
-- 6. 확인 : PK / FK 목록 (README 캡처용)
-- ---------------------------------------------------------------------
select tc.table_name,
       tc.constraint_name,
       tc.constraint_type,
       kcu.column_name,
       ccu.table_schema || '.' || ccu.table_name || '(' || ccu.column_name || ')' as references_to
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu
  on tc.constraint_name = kcu.constraint_name and tc.table_schema = kcu.table_schema
left join information_schema.constraint_column_usage ccu
  on tc.constraint_type = 'FOREIGN KEY' and tc.constraint_name = ccu.constraint_name
where tc.table_schema = 'public'
  and tc.table_name in ('members', 'products', 'orders')
  and tc.constraint_type in ('PRIMARY KEY', 'FOREIGN KEY')
order by tc.table_name, tc.constraint_type desc;
