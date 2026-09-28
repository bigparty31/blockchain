/// 백엔드 BalanceResponse 스키마 1:1 매핑
class BalanceModel {
  final int balance;
  final int income;
  final int expense;

  BalanceModel({
    required this.balance,
    required this.income,
    required this.expense,
  });

  factory BalanceModel.fromJson(Map<String, dynamic> json) {
    return BalanceModel(
      balance: json['balance'] ?? 0,
      income: json['income'] ?? 0,
      expense: json['expense'] ?? 0,
    );
  }
}
