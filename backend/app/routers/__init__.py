from app.routers.entries import router as entries_router
from app.routers.balance import router as balance_router
from app.routers.budgets import router as budgets_router

__all__ = ["entries_router", "balance_router", "budgets_router"]
