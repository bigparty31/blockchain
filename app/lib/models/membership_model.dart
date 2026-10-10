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

  /// 유효한 멤버십인지 — 발급된 적이 있고 회수(burn)되지 않았으면 유효.
  ///
  /// **`id > 0` 을 함께 본다.** [fromJson] 이 없는 필드를 기본값으로 메우기 때문에,
  /// `burnedAt` 만 보면 **빈 객체 `{}` 조차 「유효한 멤버십」이 된다** — `burned_at`
  /// 이 없으니 「회수 안 됨」으로 읽히는 것이다. 그러면 서버가 미보유를 래퍼
  /// (`{"membership": null}`)로 말했을 때 **미납 학생에게 「납부 확인됨」 배지와 빈
  /// QR 이 뜨고 이의 제기 버튼까지 열린다.**
  ///
  /// `id` 를 기준으로 쓰는 것은 **ID 채번이 1부터이고 `0` 은 「없음」으로 예약된**
  /// 값이기 때문이다 (`HASHING.md` §2.1·§8). 즉 `id == 0` 은 "멤버십을 받지 못했다"는
  /// 뜻이고, 「발급받은 적 없음」과 같게 다뤄야 한다.
  ///
  /// 지어낸 기본값으로 판정하지 않는다는 규칙은 `OnChainEntry` 와 같다.
  bool get isValid => burnedAt == null && id > 0;

  /// 입장 QR 을 그릴 수 있는지.
  ///
  /// 보유가 확인됐어도 `qr_payload` 가 비어 있으면 **QR 을 그리지 않는다** —
  /// 빈 문자열로 만든 QR 을 「납부 확인됨」 배지와 함께 띄우면, 스캐너에 찍히지
  /// 않는 코드를 학생이 입장 증명이라고 믿고 들고 가게 된다.
  bool get hasQr => isValid && qrPayload.isNotEmpty;

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
