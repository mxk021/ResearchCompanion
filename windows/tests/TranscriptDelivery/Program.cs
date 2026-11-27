using System.Text.Json;
using ResearchCompanion.Windows;

var patches = new List<TranscriptPatch>();
var results = new Queue<Task<bool>>();
var delivery = new TranscriptDelivery(patch =>
{
    patches.Add(patch);
    return results.Count > 0 ? results.Dequeue() : Task.FromResult(true);
});
var question = new TranscriptRow("question", "user", "合成问题");
var tail = new TranscriptRow("tail", "assistant", "答😀", Streaming: true);
await delivery.PushAsync("first", [question], "输入问题", 1);
Check(patches.Count == 0, "wait for renderer");
await delivery.ReadyAsync();
Check(patches[0].Order!.SequenceEqual(["question"]), "initial order");

var firstTail = new TaskCompletionSource<bool>();
results.Enqueue(firstTail.Task);
var firstSend = delivery.PushAsync("first", [question, tail], "输入问题", 1);
Check(patches.Count == 2 && patches[^1].Rows.SequenceEqual([tail]) &&
    patches[^1].Order!.SequenceEqual(["question", "tail"]), "new row and order");
var superseded = delivery.PushAsync("first", [question, tail with { Text = "答😀第一" }], "输入问题", 1);
var latest = delivery.PushAsync("first", [question, tail with { Text = "答😀最新" }], "输入问题", 1);
Check(patches.Count == 2, "single renderer call in flight");
firstTail.SetResult(true);
await Task.WhenAll(firstSend, superseded, latest);
var continuation = patches[^1];
Check(patches.Count == 3 && continuation.Order == null && continuation.Rows.Count == 1 &&
    continuation.Rows[0].AppendAfterUtf16 == 3 && continuation.Rows[0].Text == "最新", "coalesced UTF-16 continuation");
var wire = JsonSerializer.Serialize(continuation, new JsonSerializerOptions(JsonSerializerDefaults.Web));
Check(wire.Contains("\"appendAfterUTF16\":3") && !wire.Contains("\"order\""), "shared wire contract");

var rejected = new TaskCompletionSource<bool>();
results.Enqueue(rejected.Task);
var next = delivery.PushAsync("first", [question, tail with { Text = "答😀最新尝试" }], "输入问题", 1);
var final = new TranscriptRow("saved", "assistant", "保存后的答复");
var finalSend = delivery.PushAsync("first", [question, final], "输入问题", 2);
rejected.SetResult(false);
await Task.WhenAll(next, finalSend);
Check(patches.Count == 5 && patches[^1].Rows.SequenceEqual([question, final]) &&
    patches[^1].Order!.SequenceEqual(["question", "saved"]) && patches[^1].Jump == 2,
    "rejected append replays latest full state");
await delivery.PushAsync("first", [question, final], "输入问题", 2);
Check(patches.Count == 5, "unchanged state sends nothing");

var staleDocument = new TaskCompletionSource<bool>();
results.Enqueue(staleDocument.Task);
var staleSend = delivery.PushAsync("first", [question, final], "输入问题", 3);
delivery.Reset();
var newSession = delivery.PushAsync("second", [tail], "结果", 0);
var ready = delivery.ReadyAsync();
Check(patches.Count == 6, "navigation waits for prior delivery to settle");
staleDocument.SetException(new InvalidOperationException("previous renderer left"));
await Task.WhenAll(staleSend, newSession, ready);
Check(patches.Count == 7 && patches[^1].Session == "second" && patches[^1].Rows.SequenceEqual([tail]) &&
    patches[^1].Rows[0].AppendAfterUtf16 == null && patches[^1].Order!.SequenceEqual(["tail"]),
    "new document starts from full state");


var history = Enumerable.Range(0, 90).Select(index => new TranscriptRow($"past-{index}",
    index % 2 == 0 ? "user" : "assistant",
    $"第 {index} 条合成消息，" + string.Concat(Enumerable.Repeat("合成科研记录温度与实验参数。", 12)) + " 公式 $f(x)=x^2$。",
    Original: "")).ToArray();
var answer = string.Join("\n", Enumerable.Range(0, 45).Select(index => string.Join("\n\n",
    $"### 第 {index} 组", @"合成结果 $x_i^2+\alpha$，固定输出区间与取样误差，复核条件及相关附注。",
    "$$\n" + @"\begin{aligned} y &= \sum_{i=1}^k\frac{\alpha}{1+x_i^2} \\ x&=\sqrt{u^2+v^2}+" + index + @" \end{aligned}" + "\n$$", "")));
var json = new JsonSerializerOptions(JsonSerializerDefaults.Web);
long deltaBytes = 0;
var benchmark = new TranscriptDelivery(patch =>
{
    deltaBytes += JsonSerializer.SerializeToUtf8Bytes(patch, json).Length;
    return Task.FromResult(true);
});
await benchmark.ReadyAsync();
await benchmark.PushAsync("bench", history, "", 1);
deltaBytes = 0;
long fullBytes = 0;
for (int update = 1; update <= 72; update++)
{
    var row = new TranscriptRow("tail", "assistant", answer[..(answer.Length * update / 72)], Original: "",
        Streaming: update != 72);
    TranscriptRow[] rows = [.. history, row];
    fullBytes += JsonSerializer.SerializeToUtf8Bytes(new
    {
        session = "bench", rows, order = rows.Select(item => item.Id).ToArray(), emptyGuidance = "", jump = 1
    }, json).Length;
    await benchmark.PushAsync("bench", rows, "", 1);
}
Check(deltaBytes < fullBytes / 20, "long-history streaming sends substantially less JSON");
Console.WriteLine($"90 history rows, 72 updates: {fullBytes:N0} full snapshot bytes, {deltaBytes:N0} delta bytes");

static void Check(bool success, string name)
{
    if (!success) throw new InvalidOperationException("FAIL " + name);
    Console.WriteLine("PASS " + name);
}
