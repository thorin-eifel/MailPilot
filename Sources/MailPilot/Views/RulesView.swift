import SwiftUI

/// Eigene Regeln, VIP-Liste und gelernte Korrekturen.
struct RulesView: View {
    @EnvironmentObject var engine: Engine
    @ViewState private var retroCount = 0
    @ViewState private var confirmRetro = false
    @ViewState private var tests: [UUID: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !engine.suggestions.isEmpty { suggestionsCard }
                vipCard
                rulesCard
                correctionsCard
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(CTW.bg)
        .confirmationDialog("Regeln auf vorhandene Mails anwenden?", isPresented: $confirmRetro, titleVisibility: .visible) {
            Button("\(retroCount) Mails anpassen") { Task { await engine.applyRulesRetroactively() } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Bei \(retroCount) gespeicherten Mails würden Kategorie, Priorität oder Ordner geändert und in Mail umsortiert. Verschiebungen lassen sich unter „Aktivität“ rückgängig machen.")
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Automatik", number: "05")
                Text("Regeln & VIP").font(.system(size: 28, weight: .bold)).foregroundStyle(CTW.ink)
                Text("Eigene Regeln gehen vor Claude. Was du in Mail oder hier umsortierst, merkt sich MailPilot.")
                    .foregroundStyle(CTW.muted)
            }
            Spacer()
            Button {
                retroCount = engine.retroChanges().count
                if retroCount > 0 { confirmRetro = true } else { engine.status = "Keine Mail würde sich durch die Regeln ändern." }
            } label: {
                Label("Auf vorhandene Mails anwenden …", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.ctwSecondary)
            .disabled(engine.isRunning)
        }
    }

    // MARK: Vorschläge

    private var suggestionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconTile(symbol: "lightbulb.fill", color: CTW.action, size: 26)
                Eyebrow(text: "Vorschläge aus deinen Korrekturen")
            }
            ForEach(engine.suggestions) { s in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).fontWeight(.semibold).foregroundStyle(CTW.ink)
                        Text("\(s.count)× von dir so umsortiert").font(.caption).foregroundStyle(CTW.muted)
                    }
                    Spacer()
                    Button("Verwerfen") { engine.dismissSuggestion(s) }.buttonStyle(.ctwSecondary)
                    Button { engine.acceptSuggestion(s) } label: { Label("Regel anlegen", systemImage: "plus") }
                        .buttonStyle(.ctwPrimary)
                }
                .padding(10)
                .background(CTW.actionSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: CTW.radius))
            }
        }
        .ctwCard()
    }

    // MARK: VIP

    private var vipCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow(text: "VIP-Liste", number: "01")
                Spacer()
                Button { engine.settings.vips.append(VIPEntry()) } label: { Label("VIP hinzufügen", systemImage: "plus") }
                    .buttonStyle(.ctwSecondary)
            }
            Text("Mails dieser Personen oder Domains haben immer hohe Priorität – unabhängig von Claudes Einschätzung.")
                .font(.caption).foregroundStyle(CTW.muted)

            if engine.settings.vips.isEmpty {
                Label("Noch niemand eingetragen. Im Gespräch über „Absender“ lässt sich jemand direkt als VIP markieren.",
                      systemImage: "star")
                    .font(.callout).foregroundStyle(CTW.muted)
            }
            ForEach($engine.settings.vips) { $vip in
                HStack(spacing: 10) {
                    IconTile(symbol: "star.fill", color: CTW.action, size: 28)
                    TextField("Name", text: $vip.name).textFieldStyle(.roundedBorder).frame(maxWidth: 220).disabled(vip.fromContacts)
                    if vip.fromContacts { Badge(text: "Kontakte", color: CTW.accent, symbol: "person.crop.circle") }
                    TextField("Adresse oder Domain, z. B. chef@firma.de oder firma.de", text: $vip.match)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) { engine.settings.vips.removeAll { $0.id == vip.id } } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("VIP entfernen")
                }
            }
            Divider().overlay(CTW.lineSoft)
            HStack(spacing: 18) {
                Toggle("VIP-Mails markieren", isOn: $engine.settings.vipFlagEnabled)
                Picker("Flagge", selection: $engine.settings.vipFlagColor) {
                    ForEach(FlagColor.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                .disabled(!engine.settings.vipFlagEnabled)
                Toggle("Mitteilung bei neuer VIP-Mail", isOn: $engine.settings.vipNotify)
                Spacer()
            }
            .toggleStyle(.switch)
        }
        .ctwCard()
    }

    // MARK: Regeln

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow(text: "Regeln", number: "02")
                Spacer()
                Button { engine.addRule(UserRule()) } label: { Label("Regel hinzufügen", systemImage: "plus") }
                    .buttonStyle(.ctwPrimary)
            }
            Text("Von oben nach unten ausgewertet: Die erste Regel, die ein Feld setzt, gewinnt. Gilt für eingehende Mails.")
                .font(.caption).foregroundStyle(CTW.muted)

            if engine.settings.rules.isEmpty {
                Label("Noch keine Regeln. Beispiel: Absender-Domain „paypal.com“ → Kategorie „Rechnungen“, Priorität normal.",
                      systemImage: "slider.horizontal.3")
                    .font(.callout).foregroundStyle(CTW.muted)
            }
            ForEach($engine.settings.rules) { $rule in
                RuleCard(rule: $rule,
                         names: engine.settings.categories.map(\.name),
                         prefix: engine.settings.folderPrefix,
                         isFirst: engine.settings.rules.first?.id == rule.id,
                         isLast: engine.settings.rules.last?.id == rule.id,
                         testResult: tests[rule.id],
                         onMove: { engine.moveRule(rule.id, by: $0) },
                         onDelete: { engine.settings.rules.removeAll { $0.id == rule.id } },
                         onTest: {
                             let r = engine.testRule(rule)
                             tests[rule.id] = r.count == 0
                                 ? "Trifft auf keine gespeicherte Mail zu."
                                 : "Trifft auf \(r.count) gespeicherte Mails zu, z. B. " + r.examples.joined(separator: " · ")
                         })
            }
        }
        .ctwCard()
    }

    // MARK: Korrekturen

    private var correctionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow(text: "Gelernte Korrekturen", number: "03")
                Spacer()
                Toggle("Aus Korrekturen lernen", isOn: $engine.settings.learnFromCorrections).toggleStyle(.switch)
            }
            Text("Verschiebst du eine einsortierte Mail in Mail in einen anderen Ordner oder zurück in den Posteingang – oder änderst die Kategorie im Gespräch –, erkennt MailPilot das. Claude bekommt diese Korrekturen als Hinweis, und ab \(Learner.senderThreshold) gleichen Korrekturen je Absender entsteht ein Regelvorschlag.")
                .font(.caption).foregroundStyle(CTW.muted)
            if engine.corrections.isEmpty {
                Label("Noch keine Korrekturen erkannt.", systemImage: "graduationcap").font(.callout).foregroundStyle(CTW.muted)
            }
            ForEach(engine.corrections.prefix(15)) { c in
                HStack(spacing: 8) {
                    Image(systemName: c.source == "mail" ? "envelope.fill" : "rectangle.grid.2x2.fill")
                        .foregroundStyle(CTW.accent).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.senderEmail).fontWeight(.medium).foregroundStyle(CTW.ink).lineLimit(1)
                        Text(c.subject).font(.caption).foregroundStyle(CTW.muted).lineLimit(1)
                    }
                    Spacer()
                    Badge(text: c.summary, color: CTW.teal700, symbol: "arrow.right")
                    Text(c.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(CTW.muted)
                }
                .padding(.vertical, 2)
            }
        }
        .ctwCard()
    }
}

// MARK: - Regel-Karte

struct RuleCard: View {
    @Binding var rule: UserRule
    let names: [String]
    let prefix: String
    let isFirst: Bool
    let isLast: Bool
    let testResult: String?
    let onMove: (Int) -> Void
    let onDelete: () -> Void
    let onTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Toggle("Aktiv", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch)
                TextField("Name der Regel", text: $rule.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CTW.ink)
                if rule.learned { Badge(text: "Gelernt", color: CTW.accent, symbol: "graduationcap.fill") }
                if !rule.hasAction { Badge(text: "Ohne Aktion", color: CTW.action, symbol: "exclamationmark.triangle.fill") }
                Spacer()
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(isFirst).help("Weiter nach oben (höhere Priorität)")
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(isLast).help("Weiter nach unten")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).accessibilityLabel("Regel löschen")
            }

            RuleForm(rule: $rule, names: names, prefix: prefix)

            HStack(spacing: 10) {
                Button(action: onTest) { Label("Testen", systemImage: "scope") }.buttonStyle(.ctwSecondary)
                if let testResult {
                    Text(testResult).font(.caption).foregroundStyle(CTW.muted).lineLimit(2)
                }
            }
        }
        .padding(14)
        .background(CTW.surfaceSoft.opacity(rule.enabled ? 1 : 0.5), in: RoundedRectangle(cornerRadius: CTW.radius))
        .overlay(RoundedRectangle(cornerRadius: CTW.radius).strokeBorder(CTW.lineSoft))
    }
}

// MARK: - Formular (Bedingungen + Aktionen)

struct RuleForm: View {
    @Binding var rule: UserRule
    let names: [String]
    let prefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Eyebrow(text: "Wenn")
                    Picker("", selection: $rule.matchAll) {
                        Text("alle Bedingungen zutreffen").tag(true)
                        Text("mindestens eine zutrifft").tag(false)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                ForEach($rule.conditions) { $c in
                    HStack(spacing: 8) {
                        Picker("", selection: $c.field) {
                            ForEach(RuleField.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        TextField(c.field.placeholder, text: $c.value).textFieldStyle(.roundedBorder)
                        Button { rule.conditions.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(rule.conditions.count <= 1)
                            .accessibilityLabel("Bedingung entfernen")
                    }
                }
                Button { rule.conditions.append(RuleCondition()) } label: { Label("Bedingung", systemImage: "plus") }
                    .buttonStyle(.borderless).foregroundStyle(CTW.accent)
            }

            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Dann")
                HStack(spacing: 14) {
                    labeled("Kategorie") {
                        Picker("", selection: $rule.category) {
                            Text("unverändert").tag(String?.none)
                            ForEach(names, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .labelsHidden()
                    }
                    labeled("Priorität") {
                        Picker("", selection: $rule.priority) {
                            Text("unverändert").tag(Priority?.none)
                            ForEach(Priority.allCases) { Label($0.label, systemImage: $0.symbol).tag(Priority?.some($0)) }
                        }
                        .labelsHidden()
                    }
                    labeled("Flagge") {
                        Picker("", selection: $rule.flag) {
                            Text("unverändert").tag(FlagColor?.none)
                            ForEach(FlagColor.allCases) { Text($0.label).tag(FlagColor?.some($0)) }
                        }
                        .labelsHidden()
                    }
                }
                HStack(spacing: 14) {
                    labeled("Ordner") {
                        HStack(spacing: 4) {
                            Text(prefix).foregroundStyle(CTW.muted)
                            TextField("Ordner der Kategorie", text: Binding(
                                get: { rule.folder ?? "" },
                                set: { rule.folder = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .disabled(rule.keepInInbox)
                        }
                    }
                    Toggle("Im Posteingang lassen", isOn: $rule.keepInInbox).toggleStyle(.switch)
                }
                Toggle("Ohne Claude einordnen (spart Aufrufe)", isOn: $rule.skipClaude)
                    .toggleStyle(.switch)
                    .disabled(rule.category == nil)
                    .help("Mails, die diese Regel trifft, bekommen die Kategorie sofort – ohne Zusammenfassung und ohne Antwortentwurf")
            }
        }
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(CTW.muted)
            content()
        }
    }
}

// MARK: - Regel aus einem Gespräch anlegen

struct RuleEditorSheet: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @ViewState private var rule: UserRule

    init(rule: UserRule) { _rule = ViewState(initialValue: rule) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Neue Regel")
            TextField("Name der Regel", text: $rule.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15, weight: .semibold))
            RuleForm(rule: $rule, names: engine.settings.categories.map(\.name), prefix: engine.settings.folderPrefix)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.buttonStyle(.ctwSecondary).keyboardShortcut(.cancelAction)
                Button {
                    engine.addRule(rule)
                    dismiss()
                } label: { Label("Regel speichern", systemImage: "checkmark") }
                    .buttonStyle(.ctwPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!rule.hasAction || rule.conditions.allSatisfy { $0.value.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(22)
        .frame(width: 640)
        .background(CTW.surface)
    }
}
