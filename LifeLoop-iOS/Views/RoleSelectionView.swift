//
//  RoleSelectionView.swift
//  LifeLoop
//
//  Created by Jes206 on 10/6/26.
//

import SwiftUI

struct RoleSelectionView: View {
    @Binding var role: UserRole
    
    var body: some View {
        ZStack {
            Color(red: 5/255, green: 15/255, blue: 29/255).ignoresSafeArea()
            
            VStack(spacing: 40) {
                VStack(spacing: 10) {
                    Text("Welcome to LifeLoop")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    
                    Text("How will this device be used?")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.gray)
                }
                .padding(.bottom, 20)
                
                Button {
                    role = .wearer
                } label: {
                    VStack {
                        Image(systemName: "figure.walk")
                            .font(.system(size: 40))
                        Text("I am the wearer")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .background(Color(red: 24/255, green: 126/255, blue: 255/255))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                
                Button {
                    role = .family
                } label: {
                    VStack {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 40))
                        Text("I am a family member")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .background(Color(red: 0/255, green: 210/255, blue: 174/255))
                    .foregroundStyle(Color(red: 5/255, green: 15/255, blue: 29/255))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(24)
        }
    }
}
