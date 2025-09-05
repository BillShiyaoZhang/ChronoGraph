//
//  CalendarEvent.swift
//  ChronoGraph
//
//  Created by Shiyao Zhang on 05/09/2025.
//

import Foundation
import EventKit
import UIKit

struct CalendarEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String?
    let calendar: String
    let calendarColor: CGColor
    let isAllDay: Bool
    
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
        isAllDay: Bool = false
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
    }
}

enum PrivacyMode: String, CaseIterable {
    case opaque = "不透明模式"
    case partial = "部分模式"
    case full = "完整模式"
    
    var description: String {
        switch self {
        case .opaque:
            return "仅显示时间块，隐藏所有详情"
        case .partial:
            return "显示标题和时间"
        case .full:
            return "显示所有详情"
        }
    }
    
    var systemImage: String {
        switch self {
        case .opaque:
            return "eye.slash"
        case .partial:
            return "eye.trianglebadge.exclamationmark"
        case .full:
            return "eye"
        }
    }
}
