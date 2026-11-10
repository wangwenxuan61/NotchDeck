import AppKit
import SwiftUI

struct SettingsPage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var reminders = ReminderSync.shared
    @ObservedObject private var busy = LookBusyController.shared
    @ObservedObject private var language = LanguageStore.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var usage = TokenUsageStore.shared

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            content()
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            PageHeader(title: L("设置"), model: model) {
                HStack(spacing: 12) {
                    Text(L("⌥⌘N 面板  ·  ⌃⌥V 剪贴板  ·  ⌃⌥B 装忙"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                    Button(L("退出 NotchDeck")) { NSApp.terminate(nil) }.controlSize(.small)
                }
            }
            Card(padding: 10) {
                HStack(alignment: .top, spacing: 24) {
                    generalColumn.frame(maxWidth: .infinity)
                    integrationColumn.frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }

    private func menuBarChip(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isOn.wrappedValue ? Color.white : Theme.primary)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .capsuleFill(isOn.wrappedValue ? Theme.blue : Theme.control)
        }
        .buttonStyle(.plain)
    }

    private var generalColumn: some View {
        VStack(spacing: 8) {
            row(L("语言")) {
                Picker("", selection: $language.selection) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            row(L("外观")) {
                Picker("", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            row(L("开机自动启动")) {
                toggle(Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
            }
            if let error = settings.launchError {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.coral).frame(maxWidth: .infinity, alignment: .leading)
            }
            row(L("菜单栏显示")) {
                HStack(spacing: 4) {
                    menuBarChip(L("温度"), $settings.showMenuBarTemperature)
                    menuBarChip("CPU", $settings.showMenuBarCPU)
                    menuBarChip(L("网速"), $settings.showMenuBarNetwork)
                    menuBarChip(L("电池"), $settings.showMenuBarBattery)
                }
            }
            row(L("AI Token 用量")) {
                HStack(spacing: 8) {
                    if usage.isEnabled {
                        Button(L("查看")) { model.page = .usage }.controlSize(.small)
                    }
                    toggle($usage.isEnabled)
                }
            }
            .help(L("开启后，NotchDeck 只在本机读取 Claude Code 和 Codex 的用量记录，只统计模型和 token 数，不读取对话内容。"))
        }
    }

    private var integrationColumn: some View {
        VStack(spacing: 8) {
            row(L("CPU 过热提醒：%d°C", Int(settings.overheatThreshold))) {
                Slider(value: $settings.overheatThreshold, in: 70...105, step: 5).frame(width: 130).controlSize(.small)
            }
            row(L("同步系统提醒事项")) {
                HStack(spacing: 8) {
                    if reminders.isActive {
                        Picker("", selection: $reminders.selectedListID) {
                            ForEach(reminders.lists, id: \.calendarIdentifier) { list in
                                Text(list.title).tag(list.calendarIdentifier)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 120)
                    }
                    toggle(Binding(get: { reminders.isActive }, set: { reminders.setEnabled($0) }))
                }
            }
            row(L("装忙用的文件名")) {
                HStack(spacing: 8) {
                    Text(busy.usesCustomProject ? busy.project.name : L("演示项目"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    if busy.usesCustomProject {
                        Button(L("恢复演示")) { busy.useDemoProject() }.controlSize(.small)
                    }
                    Button(L("选择文件夹")) { busy.chooseProject() }.controlSize(.small)
                }
            }
            row(L("首页卡片")) {
                Button(L("自定义")) { model.page = .customize }.controlSize(.small)
            }
            row(L("自动检查更新")) {
                HStack(spacing: 8) {
                    Text(verbatim: "v\(updates.currentVersion)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .monospacedDigit()
                    if let latest = updates.latestVersion {
                        Button(L("更新到 %@", latest)) { updates.openDownloadPage() }
                            .controlSize(.small)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(updates.isChecking ? L("检查中…") : L("检查更新")) { updates.check(userInitiated: true) }
                            .controlSize(.small)
                            .disabled(updates.isChecking)
                    }
                    toggle($updates.autoCheck)
                }
            }
        }
    }
}
