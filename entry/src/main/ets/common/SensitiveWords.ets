/**
 * 客户端内容安全兜底：发布帖子、评论、聊天发送前过滤明显违规词。
 * 服务端审核仍是最终依据；这里只避免把明显敏感内容直接提交。
 */
export class SensitiveWords {
  private static readonly WORDS: string[] = [
    '傻逼', '操你', '草泥马', '色情', '赌博', '毒品', '诈骗', '代刷', '外挂',
    '政治敏感', '暴恐', '枪支', '洗钱', '裸聊'
  ];

  static clean(value: string): string {
    let result: string = value;
    for (const word of SensitiveWords.WORDS) {
      if (result.indexOf(word) >= 0) {
        result = result.split(word).join('***');
      }
    }
    return result;
  }

  static contains(value: string): boolean {
    for (const word of SensitiveWords.WORDS) {
      if (value.indexOf(word) >= 0) {
        return true;
      }
    }
    return false;
  }

  static validate(value: string, label: string): string {
    if (SensitiveWords.contains(value)) {
      return label + '包含敏感词，请修改后再提交';
    }
    return '';
  }
}
