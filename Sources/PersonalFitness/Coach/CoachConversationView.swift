import SwiftUI
import FitnessCore

/// The coach tab: one conversation, one place.
///
/// Everything else — plan generation, profile review, constraint clarification — happens *inside*
/// this conversation instead of behind a menu. The person asked for "直接跟教练聊，聊完就生成计划";
/// a grid of navigation links is the opposite of that.
///
/// Two entry points only:
/// - the conversation itself (this view)
/// - 「我的档案」, which opens the profile the coach actually uses
@MainActor
struct CoachConversationView: View {
    let store: TrainingStore
    @State private var input = ""
    @State private var issue: String?
    @State private var sending = false
    @State private var showingProfile = false
    @State private var showingInterview = false
    @State private var showingSettings = false
    @State private var infoHint: String?
    @State private var needsConstraintReview = false
    @State private var showingConstraintReview = false
    @State private var showingRecurringRestDay = false
    @State private var pendingPlanDraftID: UUID?
    @State private var planState: PlanState = .idle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the plan-generation step is doing, so the composer can say so instead of going quiet.
    private enum PlanState: Equatable {
        case idle, interviewing, generating, failed(String), planFailed(String)
    }

    private var conversation: [CoachConversationLine] { store.conversationLines }
    private var isPlanning: Bool { planState == .interviewing || planState == .generating }

    private func usableDraftID(in snapshot: AppSnapshot) -> UUID? {
        guard let draft = store.planningDrafts.first(where: {
            $0.personalization != nil && $0.decision == .pending && $0.matches(snapshot: snapshot)
        }), let session = snapshot.interview,
        session.planningEligibility(legacyRestrictions: snapshot.profile.restrictions, snapshot: snapshot).canGenerate
        else { return nil }
        return draft.id
    }

    private var usableDraftID: UUID? {
        guard let snapshot = try? store.snapshot() else { return nil }
        return usableDraftID(in: snapshot)
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
        .background(FitnessTheme.canvas)
        .navigationTitle("教练")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingProfile = true } label: {
                    Label("我的档案", systemImage: "person.text.rectangle")
                        .font(.system(size: 13, design: .rounded))
                }
                .accessibilityLabel("我的档案")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: {
                    Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("教练接口设置")
            }
        }
        .sheet(isPresented: $showingProfile, onDismiss: retryAfterReview) {
            NavigationStack { CoachProfileReviewView(store: store) }
        }
        .sheet(isPresented: $showingInterview, onDismiss: retryAfterReview) {
            NavigationStack { CoachInterviewView(store: store) }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { AISettingsView() }
        }
        .sheet(item: planSheetItem) { item in
            NavigationStack { PlanningDraftDetailView(store: store, draftID: item.id) }
        }
        .sheet(isPresented: $showingRecurringRestDay) {
            NavigationStack { RecurringRestDayView(store: store) }
        }
        .onChange(of: showingRecurringRestDay) { _, open in
            if !open { Task { await offerPlanIfPossible() } }
        }
        .sheet(isPresented: $showingConstraintReview) {
            NavigationStack { SimpleConstraintChatView(store: store) }
        }
        .onChange(of: showingConstraintReview) { _, open in
            // Returning from the constraint review is the moment the restriction became usable, so
            // try the plan again instead of making the person repeat themselves.
            guard !open else { return }
            Task { await offerPlanIfPossible() }
        }

        .onAppear { Haptics.prepare() }
        .fitnessError($issue)
    }

    /// The draft id stays available after the sheet closes, so 「看看这份计划」 can re-open the same
    /// pending draft instead of making the person talk through it again.
    /// Drives the plan sheet from `pendingPlanDraftID`, which is cleared only when the person
    /// dismisses it. The draft itself stays saved, so 「看看这份计划」 re-opens the same one instead
    /// of starting over.
    private var planSheetItem: Binding<PlanSheetItem?> {
        Binding(
            get: { pendingPlanDraftID.map(PlanSheetItem.init) },
            set: { if $0 == nil { pendingPlanDraftID = nil } })
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.isEmpty, let review = yesterdayReview {
                        yesterdayCard(review)
                    }
                    if conversation.isEmpty { greeting }
                    ForEach(conversation) { line in
                        bubble(line)
                    }
                    if sending || planState == .generating || planState == .interviewing {
                        thinkingRow
                    }
                    if case .failed(let text) = planState {
                        failureNote(text)
                    }
                    if case .planFailed(let text) = planState {
                        Text(text).font(.footnote).foregroundStyle(FitnessTheme.orange)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
            .onChange(of: conversation.count) { _, _ in
                withAnimation(reduceMotion ? nil : FitnessTheme.Motion.quick) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: sending) { _, _ in
                withAnimation(reduceMotion ? nil : FitnessTheme.Motion.quick) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                coachAvatar
                Text(greetingLine)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(FitnessTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("先告诉我你的目标、身体情况和训练条件。我会安排一周的训练，确认后生效；每天开练前再看看当天状态。")
                .font(.system(size: 12.5, design: .rounded))
                .foregroundStyle(FitnessTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: FitnessTheme.Radius.card, style: .continuous)
            .fill(FitnessTheme.surface).shadow(color: FitnessTheme.cardShadow, radius: 10, y: 4))
    }

    /// Yesterday's numbers, shown only before the conversation starts today. Once the person has
    /// talked, the transcript is the point and this would just push it down.
    private var yesterdayReview: YesterdayReview? {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))
        guard let yesterday else { return nil }
        let finished = store.sessions
            .filter { !$0.status.isOngoing && calendar.isDate($0.startedAt, inSameDayAs: yesterday) }
            .sorted { $0.startedAt > $1.startedAt }
            .first
        let weight = CalorieEstimator.bodyWeightKG(store.interview?.profile ?? StructuredProfile())
        let calories = finished.flatMap { CalorieEstimator.estimate(session: $0, weightKG: weight) }
        return YesterdayReview.make(
            session: finished,
            feedback: finished.flatMap { store.feedback(for: $0.id) },
            calories: calories,
            plan: store.scheduledPlan())
    }

    private func yesterdayCard(_ review: YesterdayReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FitnessTheme.teal)
                Text("昨天").font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(FitnessTheme.teal)
                Spacer(minLength: 0)
            }
            Text(review.headline)
                .font(.system(size: 14.5, weight: .medium, design: .rounded))
                .foregroundStyle(FitnessTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(review.details.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(FitnessTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(FitnessTheme.tealTint))
    }

    private var greetingLine: String {
        if store.currentWeeklyProgram != nil { return "我们按一周的安排来，有什么变化随时告诉我。" }
        return "先跟我说说你的情况，我来安排。"
    }

    private var coachAvatar: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [FitnessTheme.accent.opacity(0.55), FitnessTheme.accent],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 34, height: 34)
            Image(systemName: "figure.strengthtraining.functional")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func bubble(_ line: CoachConversationLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if line.isCoach { coachAvatar } else { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                // Models answer in Markdown whether or not they are asked to, so the bubble renders
                // it rather than showing literal ** and - markers.
                CoachMessageText(text: line.text, size: 15,
                                 color: line.isCoach ? FitnessTheme.ink : .white)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: line.isCoach ? 5 : 16,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: line.isCoach ? 16 : 5,
                    topTrailingRadius: 16, style: .continuous)
                    .fill(line.isCoach ? FitnessTheme.surface : FitnessTheme.accent)
            )
            if line.isCoach { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(line.isCoach ? "教练" : "我")说：\(line.text)")
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            coachAvatar
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(FitnessTheme.faint.opacity(0.55))
                        .frame(width: 6, height: 6)
                        .opacity(reduceMotion ? 0.7 : 1)
                        .animation(reduceMotion ? nil
                                   : FitnessTheme.Motion.state.repeatForever().delay(Double(index) * 0.15),
                                   value: sending)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(FitnessTheme.surface))
            Spacer(minLength: 40)
        }
    }

    private func failureNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.bubble").font(.system(size: 13)).foregroundStyle(FitnessTheme.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.system(size: 12.5, design: .rounded)).foregroundStyle(FitnessTheme.muted)
                Button("再试一次") { send(input.isEmpty ? "继续" : input) }
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(FitnessTheme.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(FitnessTheme.orangeTint))
    }

    // MARK: - Composer

    private var composer: some View {
        let draftID = usableDraftID
        return VStack(spacing: 8) {
            if let infoHint {
                Text(infoHint)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(FitnessTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isPlanning {
                Label(planState == .generating ? "正在生成一周计划…" : "正在核对生成计划所需的资料…", systemImage: "calendar")
                    .font(.footnote)
            } else if let draftID {
                Button { pendingPlanDraftID = draftID } label: {
                    Label("看看这份计划", systemImage: "calendar.badge.checkmark")
                }
                .buttonStyle(FitnessPrimaryButtonStyle())
            } else if needsConstraintReview {
                // A fortnightly appointment is a calendar fact, not a physical restriction; offering
                // the calendar editor first saves the person from a clinical flow they cannot complete.
                Button { showingRecurringRestDay = true } label: {
                    Label("登记固定休息日", systemImage: "calendar.badge.minus")
                }
                .buttonStyle(FitnessSecondaryButtonStyle())
                // The profile has the facts it needs but the recorded restriction is still raw text.
                // Without this the coach could only ever say "去核对限制" with no way to do it.
                Button { showingConstraintReview = true } label: {
                    Label("先核对训练限制", systemImage: "checkmark.shield")
                }
                .buttonStyle(FitnessPrimaryButtonStyle())
            } else if infoHint != nil {
                Button("继续核对资料") { showingInterview = true }
                    .buttonStyle(FitnessSecondaryButtonStyle())
            }
            if !isPlanning && draftID == nil && (store.interview != nil || store.currentWeeklyProgram != nil) {
                Button(store.currentWeeklyProgram == nil ? "生成一周计划" : "重新制定一周计划") {
                    Task { await offerPlanIfPossible() }
                }
                .font(.footnote)
                .disabled(sending)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("想跟教练说什么…", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: 15, design: .rounded))
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(FitnessTheme.sunken))
                    .disabled(sending || isPlanning)
                    .accessibilityLabel("给教练的消息")
                Button { send(input) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(canSend ? FitnessTheme.accent : FitnessTheme.faint.opacity(0.4)))
                }
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
        .background(FitnessTheme.surface.ignoresSafeArea(edges: .bottom))
    }

    private var canSend: Bool {
        !sending && !isPlanning && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Sending

    /// Explicit plan requests run the same draft flow as the button. Other messages remain in chat.
    private func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, !isPlanning else { return }
        input = ""
        sending = true
        planState = .idle
        Task {
            defer { sending = false }
            do {
                if InterviewSession.isPlanRequest(text) {
                    await offerPlanIfPossible()
                    return
                }
                try await store.appendCoachConversationUser(text)
                // A "don't feel like it" message gets a handled answer rather than being handed
                // straight to the model, so encouragement is consistent and never becomes nagging.
                let reply: String
                if let skip = Self.skipReply(for: text, store: store) {
                    reply = skip
                } else {
                    reply = try await CoachConversationService().reply(to: text, store: store)
                }
                try await store.appendCoachConversationCoach(reply)
                Haptics.tap()
                if Self.requestsWeeklyReplan(text) || (store.currentWeeklyProgram == nil && usableDraftID == nil) {
                    await offerPlanIfPossible()
                }
            } catch is CancellationError {
                // Nothing to say: the person cancelled.
            } catch {
                planState = .failed(error.localizedDescription)
            }
        }
    }

    private func retryAfterReview() {
        guard infoHint != nil, !sending, !isPlanning else { return }
        Task { await offerPlanIfPossible() }
    }

    static func requestsWeeklyReplan(_ text: String) -> Bool {
        guard !["不要", "不想", "不用", "别", "无需", "不需要", "保持"].contains(where: text.contains) else { return false }
        let period = ["一周", "整周", "周计划", "每周"].contains(where: text.contains)
        let change = ["重新", "重排", "调整", "修改", "换", "制定"].contains(where: text.contains)
        return period && change
    }

    /// Recognises a "I don't want to train" message and answers it locally.
    ///
    /// Doing this before the model is deliberate: the encouragement wording is a product decision
    /// (push once, with something concrete; accept pain immediately), and a model would soften it
    /// into "rest if you need to" — which is exactly the collapse the person asked to avoid.
    /// Only clearly-negative messages are intercepted; everything else goes to the coach.
    @MainActor
    private static func skipReply(for text: String, store: TrainingStore) -> String? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= 40 else { return nil }
        let skipSignals = ["不想练", "不想动", "没力气", "没精神", "好累", "太累", "懒得", "今天算了", "跳过"]
        guard skipSignals.contains(where: normalized.contains) else { return nil }
        let reason = SkipResponse.classify(normalized)
        let plan = store.scheduledPlan()
        let reply = SkipResponse.reply(to: reason, plan: plan, yesterdayTrained: trainedYesterday(store))
        var message = reply.message
        if let smaller = reply.smallerOption { message += " " + smaller }
        return message
    }

    @MainActor
    private static func trainedYesterday(_ store: TrainingStore) -> Bool {
        let calendar = Calendar.current
        return store.sessions.contains {
            !$0.status.isOngoing && calendar.isDate($0.startedAt,
                                                    inSameDayAs: calendar.date(byAdding: .day, value: -1,
                                                                               to: calendar.startOfDay(for: .now)) ?? .now)
        }
    }

    /// Opens an applicable saved draft or generates one from the reviewed profile.
    private func offerPlanIfPossible() async {
        guard !isPlanning else { return }
        planState = .interviewing
        defer { if isPlanning { planState = .idle } }
        infoHint = nil
        needsConstraintReview = false
        let service = CoachConversationService()
        do {
            let snapshot = try store.snapshot()
            if let draftID = usableDraftID(in: snapshot) {
                pendingPlanDraftID = draftID
                return
            }
            if store.interview == nil { _ = try store.startInterview() }
            _ = try service.extractFactsLocally(store: store)
            if let session = store.interview, !session.profile.isReadyForPlanning,
               session.pendingInferences.isEmpty, session.canContinueInterview,
               !(session.narratives ?? []).isEmpty {
                do { _ = try await service.extractFacts(store: store) }
                catch { infoHint = "暂时没能从聊天整理资料。\(error.localizedDescription)" }
            }
            let latest = try store.snapshot()
            guard let session = store.interview else { return }
            let eligibility = session.planningEligibility(legacyRestrictions: latest.profile.restrictions, snapshot: latest)
            guard eligibility.canGenerate else {
                infoHint = [infoHint, eligibility.message].compactMap { $0 }.joined(separator: "\n")
                needsConstraintReview = eligibility.needsConstraintReview
                return
            }
            infoHint = nil
            planState = .generating
            let draftID = try await service.draftPlan(store: store)
            pendingPlanDraftID = draftID
            Haptics.sessionSaved()
        } catch {
            planState = .planFailed("这次没能生成一周计划。" + error.localizedDescription)
        }
    }
}

/// Identifiable wrapper so a draft can drive a sheet.
struct PlanSheetItem: Identifiable, Equatable { let id: UUID }
