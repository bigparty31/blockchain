from app.routers.auth import router as auth_router
from app.routers.entries import router as entries_router
from app.routers.balance import router as balance_router
from app.routers.budgets import router as budgets_router
from app.routers.users import router as users_router

__all__ = ["auth_router", "entries_router", "balance_router", "budgets_router", "users_router"]
