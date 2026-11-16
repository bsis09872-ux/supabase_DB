"""회원(members) · 상품(products) · 주문(orders) CRUD 서비스.

모든 요청은 로그인한 사용자의 JWT로 실행되므로 DB의 RLS 정책이 그대로 적용된다.
RLS에 막힌 UPDATE/DELETE는 오류 대신 빈 결과를 돌려주므로, 빈 결과면 PermissionError로 바꿔 알린다.
"""

import os

from dotenv import load_dotenv
from postgrest.exceptions import APIError
from supabase import Client, create_client
from supabase_auth.errors import AuthApiError


def get_client() -> Client:
    load_dotenv(override=True)
    url = os.getenv("SUPABASE_URL")
    key = os.getenv("SUPABASE_PUBLISHABLE_KEY")
    if not url or not key:
        raise RuntimeError(".env에 SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY를 설정하세요.")
    return create_client(url, key)


def login(supabase: Client, email: str, password: str):
    """로그인하고, 계정이 없으면 회원가입 후 로그인한다."""
    try:
        return supabase.auth.sign_in_with_password({"email": email, "password": password}).user
    except AuthApiError:
        res = supabase.auth.sign_up({"email": email, "password": password})
        if res.session is None:
            raise RuntimeError(
                "회원가입은 됐지만 이메일 인증이 필요합니다. "
                "Authentication > Sign In / Providers > Email의 'Confirm email'을 끄고 다시 실행하세요."
            )
        return res.user


def _run(query, action: str):
    """쿼리를 실행하고 DB 오류(제약조건·RLS 위반)를 읽기 쉬운 메시지로 바꾼다."""
    try:
        return query.execute().data
    except APIError as e:
        raise ValueError(f"{action} 실패 [{e.code}] {e.message}") from e


def _require_rows(rows, action: str):
    if not rows:
        raise PermissionError(f"{action} 실패: 대상이 없거나 권한이 없습니다 (RLS).")
    return rows


class MemberService:
    """회원 CRUD: 로그인한 본인의 회원 정보만 다룬다."""

    UPDATABLE = {"name", "role", "phone", "address"}

    def __init__(self, supabase: Client):
        self.supabase = supabase
        self.table = "members"

    def _uid(self):
        user = self.supabase.auth.get_user()
        if not user or not user.user:
            raise PermissionError("로그인이 필요합니다.")
        return user.user

    def create(self, name: str, role: str = "BUYER", phone: str | None = None, address: str | None = None):
        user = self._uid()
        data = {"id": user.id, "email": user.email, "name": name, "role": role, "phone": phone, "address": address}
        return _run(self.supabase.table(self.table).insert(data), "회원 등록")[0]

    def get_me(self):
        rows = _run(self.supabase.table(self.table).select("*").eq("id", self._uid().id), "회원 조회")
        return rows[0] if rows else None

    def update(self, **fields):
        invalid = set(fields) - self.UPDATABLE
        if invalid:
            raise ValueError(f"수정할 수 없는 필드: {invalid}")
        rows = _run(self.supabase.table(self.table).update(fields).eq("id", self._uid().id), "회원 수정")
        return _require_rows(rows, "회원 수정")[0]

    def delete(self):
        rows = _run(self.supabase.table(self.table).delete().eq("id", self._uid().id), "회원 삭제")
        return _require_rows(rows, "회원 삭제")[0]


class ProductService:
    """상품 CRUD: 조회는 누구나, 등록은 SELLER만, 수정·삭제는 본인 상품만."""

    UPDATABLE = {"name", "price", "stock", "description"}

    def __init__(self, supabase: Client):
        self.supabase = supabase
        self.table = "products"

    def create(self, name: str, price: int, stock: int = 0, description: str | None = None):
        user = self.supabase.auth.get_user()
        if not user or not user.user:
            raise PermissionError("로그인이 필요합니다.")
        data = {"seller_id": user.user.id, "name": name, "price": price, "stock": stock, "description": description}
        return _run(self.supabase.table(self.table).insert(data), "상품 등록")[0]

    def list(self, keyword: str | None = None):
        query = self.supabase.table(self.table).select("id, name, price, stock, seller_id").order("id")
        if keyword:
            query = query.ilike("name", f"%{keyword}%")
        return _run(query, "상품 목록 조회")

    def get(self, product_id: int):
        rows = _run(self.supabase.table(self.table).select("*").eq("id", product_id), "상품 조회")
        return rows[0] if rows else None

    def update(self, product_id: int, **fields):
        invalid = set(fields) - self.UPDATABLE
        if invalid:
            raise ValueError(f"수정할 수 없는 필드: {invalid}")
        rows = _run(self.supabase.table(self.table).update(fields).eq("id", product_id), "상품 수정")
        return _require_rows(rows, "상품 수정")[0]

    def delete(self, product_id: int):
        rows = _run(self.supabase.table(self.table).delete().eq("id", product_id), "상품 삭제")
        return _require_rows(rows, "상품 삭제")[0]


class OrderService:
    """주문 CRUD: 로그인한 본인의 주문만 다룬다."""

    STATUSES = {"PENDING", "PAID", "SHIPPED", "DELIVERED", "CANCELED"}

    def __init__(self, supabase: Client):
        self.supabase = supabase
        self.table = "orders"

    def create(self, product_id: int, quantity: int):
        user = self.supabase.auth.get_user()
        if not user or not user.user:
            raise PermissionError("로그인이 필요합니다.")
        product = ProductService(self.supabase).get(product_id)
        if product is None:
            raise ValueError(f"존재하지 않는 상품입니다: {product_id}")
        data = {
            "member_id": user.user.id,
            "product_id": product_id,
            "quantity": quantity,
            "unit_price": product["price"],  # 주문 시점 가격을 기록
        }
        return _run(self.supabase.table(self.table).insert(data), "주문 생성")[0]

    def list_mine(self):
        query = (
            self.supabase.table(self.table)
            .select("id, quantity, unit_price, total_price, status, products(name)")
            .order("id")
        )
        return _run(query, "주문 목록 조회")

    def update_status(self, order_id: int, status: str):
        if status not in self.STATUSES:
            raise ValueError(f"허용되지 않는 주문 상태: {status}")
        rows = _run(self.supabase.table(self.table).update({"status": status}).eq("id", order_id), "주문 상태 변경")
        return _require_rows(rows, "주문 상태 변경")[0]

    def delete(self, order_id: int):
        rows = _run(self.supabase.table(self.table).delete().eq("id", order_id), "주문 삭제")
        return _require_rows(rows, "주문 삭제")[0]
