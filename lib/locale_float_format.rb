module LocaleFloatFormat
  module ApplicationHelperPatch
    def self.included(base)
      def format_object_with_locale_decimal_separator(object, html=true, &block)
        case object.class.name
        when 'Float'
          number_with_delimiter(sprintf('%.2f', object))
        else
          format_object_without_locale_decimal_separator(object, html, &block)
        end
      end

      base.class_eval do
        alias_method :format_object_without_locale_decimal_separator, :format_object
        alias_method :format_object, :format_object_with_locale_decimal_separator
      end
    end
  end

  class Hooks < Redmine::Hook::ViewListener
    def controller_issues_bulk_edit_before_save(context={ })
      separator = I18n.t('number.format.separator', default: '.')
      context[:issue].custom_field_values.map { |cfv|
        params_val = context.dig(:params,:issue,:custom_field_values, cfv.custom_field.id.to_s)
        if cfv.custom_field.field_format == 'float' && cfv.value
          cfv.value = cfv.value_was&.tr('.', separator) if params_val.nil?
        end
      }
      return ''
    end
  end

  module FloatFormatPatch
    def self.included(base)
      base.class_eval do
        def pad_number( number, min_decimals=2 )
          return number if number.blank?
          decimals = (number[/\.(\d+)/,1] || '').length
          number << "." if decimals == 0
          number << "0"*[0,min_decimals-decimals].max
        end

        def set_custom_field_value(custom_field, custom_field_value, value)
          delimiter = I18n.t('number.format.delimiter', default: ',')
          separator = I18n.t('number.format.separator', default: '.')
          if value && value.include?(',')
            value = value.sub(/.*\K#{Regexp.escape(separator)}/, '.') unless separator.empty?
            value = value.gsub(/[#{Regexp.escape(delimiter)}](?=.*[#{Regexp.escape(delimiter)}])/, '') unless delimiter.empty?
            pad_number(value)
          else
            pad_number(value&.tr(delimiter, ''))
          end
        end

        def edit_tag(view, tag_id, tag_name, custom_value, options={})
          view.text_field_tag(tag_name, ApplicationController.helpers.number_with_delimiter(pad_number(custom_value.value)), options.merge(:id => tag_id))
        end
      end
    end
  end

  module IssuePatch
    def self.included(base)
      base.class_eval do
        def copy_from(arg, options={})
          issue = arg.is_a?(Issue) ? arg : Issue.visible.find(arg)
          self.attributes = issue.attributes.dup.except("id", "root_id", "parent_id", "lft", "rgt", "created_on", "updated_on", "status_id", "closed_on")
          self.custom_field_values = issue.custom_field_values.inject({}) { |h,v|
            h[v.custom_field_id] = v.custom_field.field_format == 'float' && v.value.present? ?
              ApplicationController.helpers.number_with_delimiter(v.value.to_f) : v.value; h
          }
          if options[:keep_status]
            self.status = issue.status
          end
          self.author = User.current
          unless options[:attachments] == false
            self.attachments = issue.attachments.map do |attachement|
              attachement.copy(:container => self)
            end
          end
          unless options[:watchers] == false
            self.watcher_user_ids =
              issue.watcher_users.select{|u| u.status == User::STATUS_ACTIVE}.map(&:id)
          end
          @copied_from = issue
          @copy_options = options
          self
        end
      end
    end
  end

  module QueryPatch
    def self.included(base)
      base.class_eval do
        def add_filter(field, operator, values=nil)
          # values must be an array
          return unless values.nil? || values.is_a?(Array)

          # check if field is defined as an available filter
          if available_filters.has_key? field
            if type_for(field) == :float
              delimiter = I18n.t('number.format.delimiter', default: ',')
              separator = I18n.t('number.format.separator', default: '.')
              values = values.map { |x|
                if x.include?(',')
                  x = x.sub(/.*\K#{Regexp.escape(separator)}/, '.') unless separator.empty?
                  x = x.gsub(/[#{Regexp.escape(delimiter)}](?=.*[#{Regexp.escape(delimiter)}])/, '') unless delimiter.empty?
                  x
                else
                  x.tr(delimiter, '')
                end
              }
            end
            filters[field] = {:operator => operator, :values => (values || [''])}
          end
        end
      end
    end
  end

  module ProjectPatch
    def self.included(base)
      base.class_eval do
        def copy_issues(project)
          # Stores the source issue id as a key and the copied issues as the
          # value.  Used to map the two together for issue relations.
          issues_map = {}

          # Store status and reopen locked/closed versions
          version_statuses = versions.reject(&:open?).map {|version| [version, version.status]}
          version_statuses.each do |version, status|
            version.update_attribute :status, 'open'
          end

          # Get issues sorted by root_id, lft so that parent issues
          # get copied before their children
          project.issues.reorder('root_id, lft').each do |issue|
            new_issue = Issue.new
            new_issue.copy_from(issue, :subtasks => false, :link => false, :keep_status => true)
            new_issue.project = self
            # Changing project resets the custom field values
            # TODO: handle this in Issue#project=
            new_issue.custom_field_values = issue.custom_field_values.inject({}) do |h, v|
              h[v.custom_field_id] = v.custom_field.field_format == 'float' && v.value.present? ?
                ApplicationController.helpers.number_with_delimiter(v.value.to_f) : v.value
              h
            end
            # Reassign fixed_versions by name, since names are unique per project
            if issue.fixed_version && issue.fixed_version.project == project
              new_issue.fixed_version = self.versions.detect {|v| v.name == issue.fixed_version.name}
            end
            # Reassign version custom field values
            new_issue.custom_field_values.each do |custom_value|
              if custom_value.custom_field.field_format == 'version' && custom_value.value.present?
                versions = Version.where(:id => custom_value.value).to_a
                new_value = versions.map do |version|
                  if version.project == project
                    self.versions.detect {|v| v.name == version.name}.try(:id)
                  else
                    version.id
                  end
                end
                new_value.compact!
                new_value = new_value.first unless custom_value.custom_field.multiple?
                custom_value.value = new_value
              end
            end
            # Reassign the category by name, since names are unique per project
            if issue.category
              new_issue.category = self.issue_categories.detect {|c| c.name == issue.category.name}
            end
            # Parent issue
            if issue.parent_id
              if copied_parent = issues_map[issue.parent_id]
                new_issue.parent_issue_id = copied_parent.id
              end
            end

            self.issues << new_issue
            if new_issue.new_record?
              if logger && logger.info?
                logger.info(
                  "Project#copy_issues: issue ##{issue.id} could not be copied: " \
                    "#{new_issue.errors.full_messages}"
                )
              end
            else
              issues_map[issue.id] = new_issue unless new_issue.new_record?
            end
          end

          # Restore locked/closed version statuses
          version_statuses.each do |version, status|
            version.update_attribute :status, status
          end

          # Relations after in case issues related each other
          project.issues.each do |issue|
            new_issue = issues_map[issue.id]
            unless new_issue
              # Issue was not copied
              next
            end

            # Relations
            issue.relations_from.each do |source_relation|
              new_issue_relation = IssueRelation.new
              new_issue_relation.attributes =
                source_relation.attributes.dup.except("id", "issue_from_id", "issue_to_id")
              new_issue_relation.issue_to = issues_map[source_relation.issue_to_id]
              if new_issue_relation.issue_to.nil? && Setting.cross_project_issue_relations?
                new_issue_relation.issue_to = source_relation.issue_to
              end
              new_issue.relations_from << new_issue_relation
            end

            issue.relations_to.each do |source_relation|
              new_issue_relation = IssueRelation.new
              new_issue_relation.attributes =
                source_relation.attributes.dup.except("id", "issue_from_id", "issue_to_id")
              new_issue_relation.issue_from = issues_map[source_relation.issue_from_id]
              if new_issue_relation.issue_from.nil? && Setting.cross_project_issue_relations?
                new_issue_relation.issue_from = source_relation.issue_from
              end
              new_issue.relations_to << new_issue_relation
            end
          end
        end
      end
    end
  end
end
