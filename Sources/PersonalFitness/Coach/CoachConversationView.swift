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
        case idle, interviewing, generating, ready(UUID), failed(String)
    }

    private var conversation: [CoachConversationLine] { store.conversationLines }

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
        .sheet(isPresented: $showingProfile) {
            NavigationStack { CoachProfileReviewView(store: store) }
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
            Text("直接说你今天想怎么练、身体哪里不舒服、或者让我安排。聊够了我会给出计划，你确认后才生效。")
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
        if store.currentWeeklyProgram != nil { return "今天想练点什么？" }
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
        VStack(spacing: 8) {
            if let infoHint {
                Text(infoHint)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(FitnessTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .ready = planState {
                Button { if case .ready(let id) = planState { pendingPlanDraftID = id } } label: {
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
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("想跟教练说什么…", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: 15, design: .rounded))
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(FitnessTheme.sunken))
                    .disabled(sending)
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
        !sending && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Sending

    /// One send does both jobs: the coach answers, and once there is enough to plan, the plan is
    /// drafted and offered. There is no separate "生成训练计划" button to find.
    private func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        input = ""
        sending = true
        planState = .idle
        Task {
            defer { sending = false }
            do {
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
                await offerPlanIfPossible()
            } catch is CancellationError {
                // Nothing to say: the person cancelled.
            } catch {
                planState = .failed(error.localizedDescription)
            }
        }
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

    /// Drafts a plan when the coach has enough facts, and silently does nothing when it does not —
    /// the conversation simply continues, which is what "聊完就生成" means in practice.
    private func offerPlanIfPossible() async {
        guard store.interview != nil else { return }
        // The chat stores what the person said as narrative text; planning needs the structured
        // profile. Extracting first is what makes "聊完就出计划" actually reachable — without it the
        // profile never fills and this could only ever report missing facts.
        let service = CoachConversationService()
        // Local rules first: they never fail on format, so a chat-only endpoint can still fill the
        // profile. The model-based pass is a best-effort addition for anything the rules missed.
        _ = try? service.extractFactsLocally(store: store)
        _ = try? await service.extractFacts(store: store)
        guard let session = store.interview else { return }
        let eligibility = (try? store.snapshot()).map {
            session.planningEligibility(legacyRestrictions: $0.profile.restrictions, snapshot: $0)
        }
        guard eligibility?.canGenerate == true else {
            // Not silent: say what is still missing, and offer the action that resolves it.
            infoHint = eligibility?.message
            needsConstraintReview = eligibility?.needsConstraintReview == true
            return
        }
        needsConstraintReview = false
        infoHint = nil
        planState = .generating
        do {
            let draftID = try await service.draftPlan(store: store)
            planState = .ready(draftID)
            pendingPlanDraftID = draftID
            Haptics.sessionSaved()
        } catch {
            // A failed draft must not look like a failed conversation.
            planState = .failed("对话记下了，但这次没能整理成计划：" + error.localizedDescription)
        }
    }
}

/// Identifiable wrapper so a draft can drive a sheet.
struct PlanSheetItem: Identifiable, Equatable { let id: UUID }
