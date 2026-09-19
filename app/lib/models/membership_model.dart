/// PRD §8 Membership 모델 — 학생회비 납부자에게 발급되는 SBT (S5)
///
/// 전송 불가(Soul Bound) 멤버십이며 학기 단위로 발급된다.
/// `commit_hash` 는 **학번+salt 해시**다 — 식별정보를 온체인에 올리지 않기
/// 위한 커밋이며(PRD §302), 학번 자체가 아니다.
class MembershipModel {
  final int id;
  final int userId;
  final int termId;
  final int tokenId;
  final String commitHash;
  final int mintedAt;
  final int? burnedAt;

  /// 행사 입장 확인용 QR 에 담을 학생 식별자.
  ///
  /// **QR 에는 「납부함」을 담지 않는다** (PRD §148) —
  /// 담으면 캡처 전달만으로 뚫린다. 자격 확인은 스캐너가 조회한다.
  final String qrPayload;

  MembershipModel({
    required this.id,
    required this.userId,
    required this.termId,
    required this.tokenId,
    required this.commitHash,
    required this.mintedAt,
    this.burnedAt,
    required this.qrPayload,
  });

  /// 유효한 멤버십인지 — 회수(burn)되지 않았으면 유효.
  bool get isValid => burnedAt == null;

  factory MembershipModel.fromJson(Map<String, dynamic> json) {
    return MembershipModel(
      id: json['id'] ?? 0,
      userId: json['user_id'] ?? 0,
      termId: json['term_id'] ?? 1,
      tokenId: json['token_id'] ?? 0,
      commitHash: json['commit_hash'] ?? '',
      mintedAt: json['minted_at'] ?? 0,
      burnedAt: json['burned_at'],
      qrPayload: json['qr_payload'] ?? '',
    );
  }
}
