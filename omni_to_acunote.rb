#!/usr/bin/env ruby
require 'date.rb'
require 'rubygems'
require 'nokogiri'  #gem install nokogiri
require 'xmlsimple'
require '~/code/AcuPlan/AcuPlan.rb'

#For now always debug
DEBUG = true

file_location = ARGV[1] || (DEBUG && '/Users/bfeigin/Documents/Enova/Team/Q3_2011_bfeigin_team.oplx/Actual.xml'
puts "Missing file name to translate to omni plan, usage ./omni_to_acunote.rb file_name " unless file_location

module AcuplanTranslator

  def acunote_to_omni_priority(acu_value)
    return '' if acu_value.empty?
    6 - (acu_value.gsub(/\D/,'').to_i)
  end

  def omni_to_acunote_priority(omni_value)
    return '' unless omni_value
    'P' + (6 - (omni_value.to_i % 6)).to_s
  end

  def parse_percent(value)
      value.to_f / 100.0
  end

  def dependents
    children.map{|x| x.issue_number}.compact.join(',')
  end
  
  def remaining
    return unless @effort_required && @effort_done
    @effort_required - @effort_done
  end

  def acunote_level
    @task_level
  end

end

class OmniTask
  include AcuplanTranslator

  attr_accessor :children, :task_id, :attributes, :child_refs, :raw_data
  attr_accessor :title, :task_type, :task_level, :prerequisites, :owner_ref, :owner_name, :meta_data,
                :effort, :effort_done
  
  def initialize(raw_data, level, owner_name = nil)
    #Keep a copy of the raw data we generated the task from
    @raw_data = raw_data
   
    #Holder for any overflow info
    @meta_data = {}

    @task_level = level
    @title = raw_data['title'].first
    @task_type  = raw_data['type'] || 'task'
    @prerequisites = raw_data['prerequisite-task']
    @child_refs = (raw_data['child-task'] || []).map{|node| node['idref']}
    @owner_ref = raw_data['assignment'] && raw_data['assignment'].first['idref']
    @effort_required = (raw_data['effort'] && raw_data['effort'].first && raw_data['effort'].first.to_i/3600) 
    @priority = raw_data['priority'] && raw_data['priority'].first
    @effort_done= (raw_data['effort_done'] && raw_data['effort_done'].first && raw_data['effort_done'].first.to_i/3600) 

    if level > 4
      puts "Acunote does not currently support more then 4 levels deep"
      puts "Task #{@title} is at level #{level}, and needs to be corrected"
      exit -1
    end

    #process_user_data

    if raw_data['user-data']
      raw_data['user-data'].each do |user_data|
        if user_data['key'] == 'TaskID'
          @task_id = user_data
        end
      end
    end
    @task_id ||= ''
    #raw effort is reported in seconds we want hours
  end
  
  def to_acunote_csv
     [
      acunote_level,
      issue_number, 
      title, 
      meta_data[:Tags], 
      owner_name,
      nil,
      nil,
      omni_to_acunote_priority(@priority),
      nil,
      effort,
      remaining,
      nil,nil,nil, #Due Date,QA Owner,Business Owner,
      nil,nil, #Wiki,Watchers
      nil, #Depends_on (set by dependents)
      (('"' + dependents + '"') unless dependents.empty?), #Dependents
      nil
    ].join(',')
  end

  def to_s
    "Title: #{@title} \n children_refs: [#{@child_refs.join(", ")}] \n level #{@task_level}\n" 
  end

end


class OmniTaskGroup
  include AcunoteBase
  include AcunoteSprint

  attr_accessor :sprints, :doc, :resources

  # raw_file in is typically from a IO.read('file_name')
  def initialize(raw_file)
    @mech = Mechanize.new
    @doc = XmlSimple.xml_in(raw_file)
    @sprints     = []
    @resources = []

    acunote_login
    process_tasks
  end

  def process_tasks
    #OmniPlan indicates it's "top-task" by the top-task node so find that first
    # We get the idref for the task then do a search of the doc by id and get the root node
    root_node_id = @doc['top-task'].first['idref']
    root_node = find_tasks('id', root_node_id).first


    #Now we need to find all of the dependents of that "top-task"
    #These are the actual top level tasks
    #Each of these top level tasks will be considered a project
    projects_raw = find_tasks('id', child_refs(root_node))

    # For each project node build recursively build the tree of tasks below it
    projects_raw.each do |project_raw|
       task = OmniTask.new(project_raw, 0)
       build_children(task)
       @sprints << task
    end
    true
  end

  # Used to assign a resource name to a task by reference
  def assign_resource_name_for_task(task)
    resource = find_resource('id',task.owner_ref)
    unless resource.empty?
      task.owner_name = resource.first['name'].first
    end
  end

  # TODO 
  # This isn't complete but it does create sprints correctly albiet very slowly
  # Next step is to push the csv generated by sprints_to_csv into the sprints created (or found)
  def push_to_acunote
    test_prefix = "" || (DEBUG && "BFEIGIN TEST")
    sprint_sprint_ids = @sprints.map do |sprint|
      ref = find_sprint_by_name(test_prefix + sprint.title) || (create_sprint(test_prefix + sprint.title) && find_sprint_by_name(test_prefix + sprint.title))
      ref.href.split('/').select{|chunk| chunk =~ /\d+/}.last
    end
  end

  # Uses task_to_acunote to generate a csv of tasks for each of the sprints found during initialization
  def sprints_to_csv
    sprint_map = {}
    @sprints.each do |sprint|
      sprint_map[sprint.title] =  sprint.children.map do |root|
        task_to_acunote(root,[])
      end.flatten
    end
    sprint_map
  end

  # Acunote Format:
  # Level,Number,Description,Tags,Owner,Status,Resolution,Priority,Severity,
  # Estimate,Remaining,Due Date,QA Owner,Business Owner,Wiki,Watchers,Related,
  # Duplicate,Predecessors,Successors,Version 1
  #
  def task_to_acunote(task, to_csv)
    #Push the current task into acunote format
    to_csv << task.to_acunote_csv  

    #Then map it's children
    #This is sort of an inject but map as a verb is way more intuitive 
    if task.children.size > 0
      to_csv << task.children.map do |child|
        task_to_acunote(child, [])
      end
    end
    to_csv.flatten
  end

  #Used to recursively build a tree of tasks for a particular node
  def build_children(task, level = 0)
    #First find the resource
    assign_resource_name_for_task(task)

    # Find the child_refs of the current node
    # For each of the children refs found create a new OmniTask instance 
    # (we cheat with level because it's easier)
    task.children = find_tasks('id',child_refs(task)).map{|raw| OmniTask.new(raw, level + 1)}

    # Now take each of the children found, and recurse
    # Note we only increment level + 1 to the child calls. 
    # Each child is responsible for giving its "grand-children" the correct level
    task.children.each do |sub_task|
      build_children(sub_task, level + 1)
    end
  end


  #Finds the child idrefs of a particular node
  def child_refs(node)
    if node.is_a?(Hash)
      node['child-task'].map{|child| child['idref']}
    else
      node.child_refs 
    end
  end


  def to_s
    sprints.each do |sprint|
      sprint.to_s
    end
  end

#=== Helper Find methods to parse parts of the xml document ===#
  def find_resource(key,value)
    @resources ||= {}

    unless @resources[key]
      @resources[key] = resources.select{|res| res[key] == value}
    end

    @resources[key]
  end

  def find_tasks(key, value)
    val = if value.is_a?(Array)
      tasks.select{|task| value.include?(task[key])}
    else
      tasks.select{|task| task[key] == value}
    end
    val || []
  end

#=== so we don't have to parse quite as much ===#

  def resources
    @resources ||= @doc['resource'][1..-1]
  end

  def tasks
    @tasks ||= @doc['task']
  end
  private :tasks
end


=begin
#TODO Prereqs will require post processing, because only acunote has master "ID" number for all tasks 
# Omni -> Acunote
#   Need to create the task before you can set up a dependency so might have to be two step upload
# 
# Acu -> Omni
#   Need to be able to refence a task by Issue Number to UID mapping

####################### CONVERSION STRAT #####################

#ACUNOTE TO OMNI
Number, Issue, val
Description, Task, val
Owner, Assigned, val
Priority, Priority, acunote_to_omni_priority(val)
Estimate, Effort, val+'h'
Remaining, Completed (val.to_f/acu_data[Estimate].to_f) + '%'



########################## OMNI TO ACUNOTE ############################
#OmniPlan, Acunote, proc 

OMNI_DAY_TO_ACUNOTE_HOUR_CONVERSION_RATE = Hash.new(5) #Default everyone to 5 hours for now



ID, Level,  omni_to_acunote_level_conversion(val)
#Task, Description, val
#End, Due Date, Date.parse(val)
#Effort, Estimate, val.to_i #omni_to_acu_time(val)
#Completed, Remaining, parse_percent(val) * Estimate.to_f
#Issue, Number, val.to_i
#Assigned, Owner, val.split.first
#Priority, Priority, omni_to_acunote_priority(val)
#Task Type, Is Group, val ~= /Group/





#META DATA ONLY
Start
Duration
Task Cost
Planned Start
Planned End
Notes

##################### END CONVERSION STRAT ################
  def to_s
    sprints.each do |sprint|
      sprint.to_s
    end
  end

=end
