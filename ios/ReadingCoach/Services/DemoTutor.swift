import Foundation

enum DemoTutor {
    static let sampleTitle = "サンプル：Evidence and decisions"
    static let sampleText = """
    A test may pass without showing that the implementation meets every requirement. The test provides evidence about the cases it checks, rather than a guarantee about every possible case.

    Before approving the change, the team checked whether any customers still used the old devices. The report described the question, but it did not reveal the answer.

    The team may be maintaining an unnecessary restriction as opposed to useful consistency. A useful review asks whether the original reason still applies.
    """

    static func reply(source: String) -> String {
        if source.contains("without showing") { return "テストが通ることと、実装がすべての要件を満たすと確認できることは別です。without showing は『示さないままでも』という関係で、要件違反が必ずあるとは述べていません。" }
        if source.contains("checked whether") { return "確認した内容は『古い端末を使う顧客がまだいるかどうか』です。実際に顧客がいたか、変更を承認したかという結果は、この文だけでは分かりません。" }
        if source.contains("as opposed to") { return "『有益な一貫性を保っているというより、不要な制限を維持しているかもしれない』という対比です。may は可能性を表し、断定ではありません。" }
        return "これは固定のDemo応答です。主体と動作を確認し、可能性・対比・否定の関係に注目して、保存した原文を読み直してみましょう。Liveの評価や音声認識は行っていません。"
    }
}
