import SwiftUI
import FitnessCore

/// An ordinary conversation first; the saved review is produced only by the final readback action.
@MainActor
struct SimpleConstraintChatView: View {
    let store: TrainingStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool
    @State private var input = ""
    @State private var request: Task<Void, Never>?
    @State private var requestID: UUID?
    @State private var configuration: AIConfiguration?
    @State private var issue: String?
    @State private var notice: String?
    @State private var loaded = false
    @State private var editing = false
    @State private var automaticInquiryStarted = false
    @State private var restDate = Date()

    private var chat: ConstraintChatSession? { store.interview?.constraintChat }
    private var latestCandidate: ConstraintChatCandidate? {
        guard let chat, sourcesMatch(chat),
              chat.candidateEvidenceCount == chat.messages.filter({ $0.role == .user }).count else { return nil }
        return chat.candidate
    }
    private var openQuestions: [String] {
        guard let candidate = latestCandidate else { return [] }
        return candidate.questions + candidate.unresolved
    }
    private var needsProfessionalDetails: Bool {
        chat?.mode == .professionalBoundaries && ((chat?.professionalNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || latestCandidate?.allowedExerciseIDs?.isEmpty != false)
    }
    private var hasFreshPainAnswer: Bool {
        guard let date = chat?.painFreeAnsweredAt else { return false }
        return date <= Date() && Calendar.current.isDateInToday(date)
    }
    private var mayReadBack: Bool {
        latestCandidate != nil && (openQuestions.isEmpty || (chat?.mode == .affectedDaysRest && chat?.restScopeConfirmed == true)) && chat?.mode != nil && chat?.painFree == true
            && hasFreshPainAnswer && !needsProfessionalDetails && !editing && request == nil
    }
    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasSavedEvidence: Bool {
        guard let chat else { return false }
        return !chat.sourceText.isEmpty || !chat.legacySourceText.isEmpty || !chat.messages.isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introduction
                    ForEach(chat?.messages ?? []) { message in messageBubble(message) }
                    if request != nil {
                        HStack(spacing: 10) { ProgressView(); Text("教练正在看你说的情况…").foregroundStyle(.secondary) }
                            .padding(.vertical, 8)
                    } else {
                        nextStep
                    }
                    if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }.padding(20)
            }
            .background(FitnessTheme.canvas)
            .onChange(of: chat?.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) {
                if !mayReadBack && (chat?.mode != .affectedDaysRest || latestCandidate == nil || editing) { composer }
            }
        }
        .navigationTitle("训练注意事项").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if chat?.mode == .affectedDaysRest {
                    Button("修改休息日") { editRestScope { $0.restScopeConfirmed = nil } }
                } else if chat?.mode == .gentleActivity {
                    Button("继续说明") { editing = true; typing = true }
                } else {
                    NavigationLink("详细编辑") { ConstraintReviewView(store: store) }
                }
            }
        }
        .onAppear { load() }
        .onDisappear { cancelRequest() }
        .fitnessError($issue)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("先聊清楚，再安排").font(.title2.bold())
            Text("告诉教练你的身体状况和需要注意的事；如何安排训练交给教练。")
                .foregroundStyle(.secondary)
            if hasSavedEvidence {
                DisclosureGroup("看看已经记下的注意事项") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let source = chat?.sourceText, !source.isEmpty { Text(source) }
                        if let legacy = chat?.legacySourceText, !legacy.isEmpty, legacy != chat?.sourceText { Text(legacy) }
                    }.font(.callout).padding(.top, 8)
                }.font(.callout)
            }
        }
    }

    private func messageBubble(_ message: ConstraintChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 6) {
                Text(message.role == .user ? "我" : "教练").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(message.text).textSelection(.enabled)
            }
            .padding(15)
            .background(message.role == .user ? FitnessTheme.blueTint : FitnessTheme.surface,
                        in: RoundedRectangle(cornerRadius: 18))
            if message.role == .coach { Spacer(minLength: 32) }
        }
    }

    @ViewBuilder private var nextStep: some View {
        if configuration == nil && latestCandidate == nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("连接你自己的AI教练后，就能从这里继续聊。原话会先保存在手机上。")
                NavigationLink("连接我的教练") { AISettingsView() }.buttonStyle(.bordered)
            }.chatCard()
        } else if latestCandidate != nil && chat?.mode == .affectedDaysRest && chat?.restScopeConfirmed != true {
            restScopeCard
        } else if !openQuestions.isEmpty && chat?.mode != .affectedDaysRest {
            VStack(alignment: .leading, spacing: 10) {
                Text("先回答这一件就好").font(.headline)
                if chat?.messages.last(where: { $0.role == .coach })?.text != openQuestions[0] {
                    Text(openQuestions[0])
                }
                if openQuestions.count > 1 {
                    DisclosureGroup("还有需要慢慢聊清楚的事") {
                        ForEach(Array(openQuestions.dropFirst().enumerated()), id: \.offset) { _, question in
                            Text(question).font(.callout).padding(.vertical, 4)
                        }
                    }.font(.callout)
                }
                Text("知道多少说多少；不确定就告诉教练。回答后点“发给教练”，继续聊。")
                    .font(.footnote).foregroundStyle(.secondary)
                restAlternative
            }.chatCard()
        } else if let candidate = latestCandidate, let dateKey = candidate.gentleDateKey, chat?.mode == nil {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(dateKey) 可以做轻松的日常活动吗？").font(.headline)
                Text("我会按你的情况安排当天内容，不用你列动作。若治疗人员要求不活动，请如实告诉我。")
                Button("可以轻松活动") { recordGentleActivity() }.buttonStyle(.borderedProminent)
                Button("不能／不确定，我再说说") { typing = true }.buttonStyle(.bordered)
            }.chatCard()
        } else if latestCandidate != nil, chat?.mode == nil {
            VStack(alignment: .leading, spacing: 14) {
                Text("避开这些动作，主要是因为什么？").font(.headline)
                Button("不习惯、不喜欢，或时间不方便") {
                    recordMode(.practicalOnly, text: "这些注意事项是动作习惯、能力、偏好或时间安排，不涉及尚未明确的身体、疼痛或恢复问题。")
                }.buttonStyle(.bordered).frame(minHeight: 44)
                Button("身体、治疗或恢复方面的原因") {
                    recordMode(.professionalBoundaries, text: "这些注意事项涉及身体、治疗或恢复，需要按具体专业指导安排。")
                }.buttonStyle(.bordered).frame(minHeight: 44)
                Text("身体原因还没弄清楚时，选第二项继续说明。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.chatCard()
        } else if latestCandidate != nil, needsProfessionalDetails {
            VStack(alignment: .leading, spacing: 10) {
                Text("专业人士具体允许你怎么活动？").font(.headline)
                Text("把允许的具体动作、需要避开的情况和其他要求告诉教练。还没问清楚也可以直接说；教练会继续追问。")
                Text("一句“可以运动”还不足以安排动作。这里记录你的转述，不会由AI给出医疗许可。")
                    .font(.footnote).foregroundStyle(.secondary)
                restAlternative
            }.chatCard()
        } else if latestCandidate != nil, chat?.painFree == nil || !hasFreshPainAnswer {
            VStack(alignment: .leading, spacing: 14) {
                Text("现在有疼痛或其他不舒服吗？").font(.headline)
                HStack {
                    Button("没有") { recordPainFree(true) }.buttonStyle(.borderedProminent)
                    Button("有／说不清") { recordPainFree(false) }.buttonStyle(.bordered)
                }.controlSize(.large)
                Text("这件事由你本人回答，教练不会替你判断。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.chatCard()
        } else if chat?.painFree == false {
            VStack(alignment: .leading, spacing: 12) {
                Text("先把不舒服的情况弄清楚").font(.headline)
                Text("先不按这次整理安排训练。可以继续告诉教练哪里不舒服，并向专业人士确认适合的活动。原来的计划和记录都还在。")
                Button("重新回答现在的情况") { clearPainAnswer() }.buttonStyle(.bordered)
            }.chatCard()
        } else if mayReadBack, let conversation = chat {
            VStack(alignment: .leading, spacing: 14) {
                Text("我理解的是…").font(.title3.bold())
                ForEach(Array(conversation.readbackLines.enumerated()), id: \.offset) { _, line in
                    Label(line, systemImage: "checkmark").labelStyle(.titleAndIcon)
                }
                Text(chat?.mode == .affectedDaysRest ? "这些未明确事项继续保留；所选时段只休息。其他日期仍按你已确认的条件核对。" : (chat?.mode == .gentleActivity ? "教练会为这一天安排轻松活动，其他日期按计划安排。" : (chat?.mode == .professionalBoundaries ? "按你记录的专业指导范围安排。" : "这些是你说明的习惯、能力、偏好和时间安排。")))
                    .font(.callout).foregroundStyle(.secondary)
                if chat?.mode == .professionalBoundaries, let note = chat?.professionalNote {
                    Text("你记录的具体指导：\(note)").font(.callout)
                }
                Text("你刚才确认：现在没有疼痛或异常不适。若还有遗漏，请先改一下。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("对，按这些安排") { confirm() }.buttonStyle(FitnessPrimaryButtonStyle())
                Button("改一下") { editing = true; typing = true }.frame(maxWidth: .infinity, minHeight: 44)
            }.chatCard()
        } else if editing {
            Text("还想改哪一点？直接在下面告诉教练。").font(.headline)
        } else if chat?.messages.isEmpty == false {
            Text("你的话已保存。不用再想话题，可以请教练根据已有资料继续问。").foregroundStyle(.secondary)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(needsProfessionalDetails ? "把具体指导告诉教练…" : "用自己的话说就好…", text: $input, axis: .vertical)
                .lineLimit(2...5).focused($typing)
                .padding(12).background(FitnessTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
                .disabled(request != nil)
            Text("发送内容：已记下的注意事项、本人补充、本页对话和动作名称；发送到你设置的AI服务。")
                .font(.caption).foregroundStyle(.secondary)
            if configuration == nil {
                NavigationLink("连接我的教练") { AISettingsView() }.font(.callout)
            }
            if request != nil {
                Button("先停一下") { cancelRequest(); notice = "原话已保存，下次可以接着聊。" }
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Button(trimmedInput.isEmpty ? "请教练根据已有资料继续问" : "发给教练") { send() }.buttonStyle(FitnessPrimaryButtonStyle())
                    .disabled(configuration == nil || (!hasSavedEvidence && trimmedInput.isEmpty))
            }
        }.padding(16).background(FitnessTheme.surface)
    }

    private var restAlternative: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("暂时说不清这些时段能做哪些动作？可以先留作休息，不必反复让专业人士点名动作。")
                .font(.callout).foregroundStyle(.secondary)
            Button("受影响的日子先休息") {
                editRestScope { conversation in
                    conversation.setMode(.affectedDaysRest)
                    if conversation.candidate?.questions.isEmpty == true && conversation.candidate?.unresolved.isEmpty == true {
                        conversation.candidate?.unresolved = ["专业活动范围尚未明确，受影响时段暂不安排运动"]
                    }
                }
            }.buttonStyle(.bordered).frame(minHeight: 44)
        }
    }

    private var restScopeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("先把这些日子留作休息").font(.title3.bold())
            Text("下面这些要求仍未明确，不会当成运动许可。请选出全部受影响时段；其他日子也不确定时，先不要确认。")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(Array(Array(Set(openQuestions)).sorted().enumerated()), id: \.offset) { _, text in
                Text("• " + text).font(.callout)
            }
            Text("每周固定休息（每周都会生效）").font(.headline)
            ForEach(1...7, id: \.self) { day in
                Toggle(PlanningDisplay.weekday(day), isOn: Binding(get: {
                    latestCandidate?.excludedWeekdays.contains(day) == true
                }, set: { selected in
                    editRestScope { conversation in
                        var days = Set(conversation.candidate?.excludedWeekdays ?? [])
                        if selected { days.insert(day) } else { days.remove(day) }
                        conversation.candidate?.excludedWeekdays = days.sorted()
                    }
                }))
            }
            Text("隔周或单次安排，请添加具体日期；不会猜测治疗间隔。")
                .font(.caption).foregroundStyle(.secondary)
            DatePicker("具体休息日", selection: $restDate, displayedComponents: .date)
            Button("添加这个休息日") {
                let key = TrainingConstraintReview.dateKey(restDate)
                editRestScope { conversation in
                    let dates = (conversation.candidate?.restDateKeys ?? []) + [key]
                    conversation.candidate?.restDateKeys = Array(Set(dates)).sorted()
                }
            }.frame(minHeight: 44)
            ForEach(latestCandidate?.restDateKeys ?? [], id: \.self) { key in
                HStack { Text(key); Spacer(); Button("移除") {
                    editRestScope { $0.candidate?.restDateKeys.removeAll { $0 == key } }
                }.frame(minHeight: 44) }
            }
            Text("以上未明确事项，是否只影响所选休息日？其他训练日还有额外未说明的身体限制吗？").font(.headline)
            Button("仅影响这些休息日，其他日期没有额外未说明限制") {
                editRestScope(confirming: true) { $0.restScopeConfirmed = true }
            }.buttonStyle(FitnessPrimaryButtonStyle())
                .disabled((latestCandidate?.excludedWeekdays.isEmpty ?? true) && (latestCandidate?.restDateKeys.isEmpty ?? true))
            Button("其他日子也有限制／还不能确定") {
                editRestScope { $0.setMode(.professionalBoundaries) }
                notice = "原资料已保留。其他日期也不确定时，不会据此安排训练；请继续说明还受哪些限制。"
            }.frame(minHeight: 44)
        }.chatCard()
    }

    private func editRestScope(confirming: Bool = false, _ mutation: (inout ConstraintChatSession) -> Void) {
        do {
            guard var session = store.interview, var conversation = session.constraintChat,
                  sourcesMatch(conversation), conversation.candidateEvidenceCount == conversation.userMessageCount else {
                throw CoreError.invalidState("资料有更新，请先让教练重新整理。")
            }
            if !confirming { conversation.restScopeConfirmed = nil; conversation.setPainFree(nil) }
            mutation(&conversation)
            try conversation.validate()
            session.constraintChat = conversation
            try store.saveInterview(session)
        } catch { issue = error.localizedDescription }
    }

    private func sourcesMatch(_ chat: ConstraintChatSession) -> Bool {
        chat.sourceText == (store.interview?.profile.restrictions.value ?? "")
            && chat.legacySourceText == store.profile.restrictions
    }

    private func load() {
        configuration = try? AIConfigurationStorage.load()
        do {
            var session = try store.interview ?? store.startInterview()
            var conversation = session.constraintChat ?? ConstraintChatSession(
                sourceText: session.profile.restrictions.value ?? "", legacySourceText: store.profile.restrictions)
            if !sourcesMatch(conversation) {
                conversation.sourceText = session.profile.restrictions.value ?? ""
                conversation.legacySourceText = store.profile.restrictions
                conversation.candidateEvidenceCount = nil; conversation.confirmedAt = nil
                notice = "注意事项更新了。以前聊过的话还在，请让教练再看一次。"
            }
            if !loaded && !isIsolatedReadbackCapture { conversation.setPainFree(nil, at: Date()) }
            session.constraintChat = conversation
            try store.saveInterview(session)
            loaded = true
            if !automaticInquiryStarted && !isIsolatedReadbackCapture && configuration != nil
                && latestCandidate == nil && hasSavedEvidence {
                automaticInquiryStarted = true
                send()
            }
        } catch { issue = error.localizedDescription }
    }

    private func recordMode(_ mode: ConstraintReviewMode, text: String) {
        do {
            guard var session = store.interview, var conversation = session.constraintChat,
                  sourcesMatch(conversation) else { throw CoreError.invalidState("注意事项有更新，请返回后重新打开。") }
            conversation.setMode(mode)
            try session.addNarrative(text)
            // This exact, visible human classification applies to the current readback.
            session.constraintChat = conversation
            try store.saveInterview(session)
        } catch { issue = error.localizedDescription }
    }

    private func recordGentleActivity() {
        do {
            guard var session = store.interview, var conversation = session.constraintChat,
                  sourcesMatch(conversation), conversation.candidate?.gentleDateKey != nil else {
                throw CoreError.invalidState("情况有更新，请先让教练重新整理。")
            }
            conversation.setMode(.gentleActivity)
            conversation.gentleActivityAllowed = true
            try session.addNarrative("本人确认所述日期可以做轻松日常活动。")
            session.constraintChat = conversation
            try store.saveInterview(session)
        } catch { issue = error.localizedDescription }
    }

    private func recordPainFree(_ value: Bool) {
        do {
            guard var session = store.interview, var conversation = session.constraintChat,
                  sourcesMatch(conversation) else { throw CoreError.invalidState("注意事项有更新，请返回后重新打开。") }
            let date = Date()
            conversation.setPainFree(value, at: date)
            try session.addNarrative(value ? "本人确认现在没有疼痛或异常不适。" : "本人表示现在有疼痛、其他不适或不能确定。", at: date)
            session.constraintChat = conversation
            try store.saveInterview(session)
        } catch { issue = error.localizedDescription }
    }

    private func clearPainAnswer() {
        do {
            guard var session = store.interview, var conversation = session.constraintChat else { return }
            conversation.setPainFree(nil, at: Date()); session.constraintChat = conversation
            try store.saveInterview(session)
        } catch { issue = error.localizedDescription }
    }

    private func send() {
        guard request == nil, let configuration else { return }
        do {
            guard let key = try AIKeychain.load(for: configuration) else { throw CoachClientError.configuration("先到“连接我的教练”填写API密钥，就能继续聊。") }
            guard var session = store.interview, var conversation = session.constraintChat,
                  sourcesMatch(conversation) else { throw CoreError.invalidState("注意事项有更新，请返回后重新打开，之前的对话仍保留。") }
            let text = trimmedInput
            guard text.count <= 6_000 else { throw CoreError.invalidInput("这次先说6000字以内，剩下的可以接着聊。") }
            if !text.isEmpty {
                let date = Date()
                if conversation.mode == .professionalBoundaries {
                    let combined = conversation.professionalNote.isEmpty ? text : conversation.professionalNote + "\n" + text
                    guard combined.count <= 2_000 else { throw CoreError.invalidInput("具体指导的记录先保持在2000字以内；其他情况可以另行补充给教练。") }
                    conversation.professionalNote = combined
                }
                try conversation.appendUser(text, at: date)
                session.constraintChat = conversation
                try session.addNarrative(text, at: date)
                try store.saveInterview(session)
                input = ""; editing = false
            }
            guard let start = store.interview, let savedChat = start.constraintChat else { return }
            let legacy = store.profile.restrictions
            let evidenceCount = savedChat.messages.filter { $0.role == .user }.count
            let token = UUID(); requestID = token; notice = nil; typing = false
            request = Task {
                defer { if requestID == token { request = nil; requestID = nil } }
                let api = SimpleConstraintChatAPI()
                // Step 1: the coach talks. This step cannot fail on formatting, so the person always
                // gets an answer. Step 2 (extraction) may fail without taking the conversation down.
                let turn: CoachConversationTurn
                do {
                    turn = try await api.converse(session: start, legacyRestrictions: legacy,
                                                  configuration: configuration, key: key)
                } catch is CancellationError { return }
                catch {
                    if requestID == token { issue = error.localizedDescription }
                    return
                }
                try? Task.checkCancellation()
                guard requestID == token, store.interview == start,
                      var current = store.interview, var saved = current.constraintChat,
                      saved.sourceText == savedChat.sourceText, saved.legacySourceText == savedChat.legacySourceText,
                      saved.messages.filter({ $0.role == .user }).count == evidenceCount else {
                    if requestID == token { issue = "刚才的资料有更新。这次回复没有覆盖新内容，请再发给教练。" }
                    return
                }
                // Show the coach's line immediately; extraction is a separate, slower concern.
                do { try saved.appendCoach(turn.reply, at: Date()) } catch { }
                current.constraintChat = saved
                try? store.saveInterview(current)

                // Step 2: structure what has been said so far, including the line just shown. A
                // failure here is reported quietly and the conversation stays usable — the person
                // can keep talking or confirm later.
                do {
                    guard let latestSession = store.interview else { return }
                    let candidate = try await api.reply(session: latestSession, legacyRestrictions: legacy,
                                                        configuration: configuration, key: key)
                    try Task.checkCancellation()
                    guard requestID == token, var latest = store.interview, var chat = latest.constraintChat,
                          chat.sourceText == savedChat.sourceText,
                          chat.legacySourceText == savedChat.legacySourceText,
                          chat.messages.filter({ $0.role == .user }).count == evidenceCount else { return }
                    try chat.receiveCandidate(candidate, evidenceCount: evidenceCount, at: Date())
                    if candidate.questions.isEmpty && candidate.unresolved.isEmpty { chat.setMode(nil) }
                    latest.constraintChat = chat
                    try store.saveInterview(latest)
                } catch is CancellationError { }
                catch {
                    if requestID == token {
                        // Not an alert: the conversation succeeded, only the bookkeeping did not.
                        notice = "教练已经回答了你，但这次的整理没有完成。可以继续聊，或稍后再试。"
                    }
                }
            }
        } catch { issue = error.localizedDescription }
    }

    private func confirm() {
        guard mayReadBack else { return }
        do {
            guard var session = store.interview, var conversation = session.constraintChat,
                  sourcesMatch(conversation) else { throw CoreError.invalidState("注意事项有更新，请先重新聊清楚。") }
            let date = Date()
            let review = try conversation.makeReview(at: date)
            try session.confirmConstraintReview(review, at: date)
            conversation.confirmedAt = date; session.constraintChat = conversation
            try store.saveInterview(session)
            dismiss()
        } catch { issue = error.localizedDescription }
    }

    private func cancelRequest() {
        requestID = nil; request?.cancel(); request = nil
    }

    private var isIsolatedReadbackCapture: Bool {
        #if DEBUG
        return (ProcessInfo.processInfo.arguments.contains("--capture-constraint-readback") || ProcessInfo.processInfo.arguments.contains("--capture-constraint-deferred-readback") || ProcessInfo.processInfo.arguments.contains("--capture-constraint-gentle-readback"))
            && ConstraintValidationData.isActive && store.storageURL == nil
        #else
        return false
        #endif
    }
}

private extension View {
    func chatCard() -> some View {
        self.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}
