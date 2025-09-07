//
//  CalendarEvent.swift
//  ChronoGraph
//
//  Created by Shiyao Zhang on 05/09/2025.
//

import Foundation
import EventKit
import UIKit
import SwiftUI // 新增: 用于颜色表示

struct CalendarEvent: Identifiable, Hashable {
    // 将嵌套类型提前声明，避免某些解析器前向引用潜在问题
    enum Availability: String, CaseIterable, Hashable {
        case busy, free, tentative, unavailable, notSupported
        init(ekEventAvailability: EKEventAvailability) {
            switch ekEventAvailability {
            case .busy: self = .busy
            case .free: self = .free
            case .tentative: self = .tentative
            case .unavailable: self = .unavailable
            default: self = .notSupported
            }
        }
        var localizedName: String {
            switch self {
            case .busy: return "忙碌"
            case .free: return "空闲"
            case .tentative: return "暂定"
            case .unavailable: return "不可用"
            case .notSupported: return "未知"
            }
        }
        var color: Color {
            switch self {
            case .busy: return .red
            case .free: return .green
            case .tentative: return .orange
            case .unavailable: return .gray
            case .notSupported: return .secondary
            }
        }
    }
    
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String?
    let calendar: String
    let calendarColor: CGColor
    let isAllDay: Bool
    let availability: Availability // 新增：忙碌状态
    
    init(from ekEvent: EKEvent) {
        self.id = ekEvent.eventIdentifier
        self.title = ekEvent.title ?? "No Title"
        self.startDate = ekEvent.startDate
        self.endDate = ekEvent.endDate
        self.location = ekEvent.location
        self.notes = ekEvent.notes
        self.calendar = ekEvent.calendar.title
        self.calendarColor = ekEvent.calendar.cgColor
        self.isAllDay = ekEvent.isAllDay
        self.availability = Availability(ekEventAvailability: ekEvent.availability)
    }
    
    // 便于预览/单元测试的便捷初始化
    init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil,
        notes: String? = nil,
        calendar: String,
        calendarColor: CGColor = UIColor.systemBlue.cgColor,
        isAllDay: Bool = false,
        availability: Availability = .busy
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.notes = notes
        self.calendar = calendar
        self.calendarColor = calendarColor
        self.isAllDay = isAllDay
        self.availability = availability
    }
}

enum PrivacyMode: String, CaseIterable {
    case opaque = "不透明模式"
    case partial = "部分模式"
    case full = "完整模式"
    
    var description: String {
        switch self {
        case .opaque: return "仅显示时间块，隐藏所有详情"
        case .partial: return "显示标题和时间"
        case .full: return "显示所有详情"
        }
    }
    
    var systemImage: String {
        switch self {
        case .opaque: return "eye.slash"
        case .partial: return "eye.trianglebadge.exclamationmark"
        case .full: return "eye"
        }
    }
}
