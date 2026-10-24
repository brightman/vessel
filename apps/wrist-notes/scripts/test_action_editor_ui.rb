#!/usr/bin/env ruby

root = File.expand_path("..", __dir__)
list_source = File.read(File.join(root, "Sources/iPhone/ActionViews.swift"))
reminder_source = File.read(File.join(root, "Sources/iPhone/DaybookReminderViews.swift"))
daybook_source = File.read(File.join(root, "Sources/iPhone/DaybookView.swift"))
settings_source = File.read(File.join(root, "Sources/iPhone/SettingsViews.swift"))

action_list = list_source.split("struct ActionEditor: View", 2).first
action_editor = list_source.split("struct ActionEditor: View", 2).last&.split("struct ActionDetailView: View", 2)&.first
editor_route = list_source.split("struct ActionEditor: View", 2).first
reminder_editor = reminder_source.split("struct DaybookReminderEditor: View", 2).last&.split("struct DaybookPreferencesView: View", 2)&.first
data_page = daybook_source.split("private var dataPage: some View", 2).last&.split("private func sourceRow", 2)&.first
daybook_sheet = daybook_source.split("private enum DaybookSheet: Hashable, Identifiable", 2).last&.split("private enum DaybookFilter", 2)&.first
about_view = settings_source.split("struct AboutView: View", 2).last&.split("struct AISettingsView: View", 2)&.first

abort "missing independent add-action button" unless action_list&.include?("accessibilityLabel(\"新建行动\")")
abort "new and edit routes must carry their action item and mode together" unless editor_route&.include?("private enum ActionEditorRoute: Identifiable") && editor_route&.include?("case create(ActionItem)") && editor_route&.include?("case edit(ActionItem)")
abort "independent add-action button must open a create route" unless action_list&.include?("editorRoute = .create(ActionItem(kind:.todo,title:\"\"))")
abort "existing action entry must open an edit route" unless action_list&.include?("editorRoute = .edit(item)")
abort "editor sheet must derive mode from its route" unless action_list&.include?("ActionEditor(store:store,item:route.item,isNew:route.isNew)")
abort "new action editor must show a create title" unless action_editor&.include?("if isNew { return \"新建行动\" }")
abort "action editor is missing the shared sheet layout" unless action_editor&.include?("DaybookSheetLayout(")
abort "action editor still uses the platform Form style" if action_editor&.include?("Form {")
abort "action editor is missing the shared field treatment" unless action_editor&.include?("DaybookSettingsField(")
abort "action editor is missing the shared cancel/save actions" unless action_editor&.include?("DaybookSettingsActions(")
abort "reminder editor must use the same sheet layout" unless reminder_editor&.include?("DaybookSheetLayout(")
abort "reminder editor must use the same field treatment" unless reminder_editor&.include?("DaybookSettingsField(")
abort "reminder editor must use the same cancel/save actions" unless reminder_editor&.include?("DaybookSettingsActions(")
abort "main settings must expose the about page" unless data_page&.include?("present(.about)") && daybook_sheet&.include?(", about")
abort "about page must include FAQ, privacy, terms, and contact destinations" unless about_view&.include?("常见问题") && about_view&.include?("隐私条款") && about_view&.include?("服务条款") && about_view&.include?("联系我们")

puts "Action editor UI contract passed"
